#!/usr/bin/env bash
# Verify Harbor credentials and push permission before expensive image builds.
#
# 必要环境变量：
#   REGISTRY         Harbor 地址（不含 scheme），如 harbor.gxrs.net
#   IMAGE_PREFIX     镜像前缀，如 library/weknora
#   HARBOR_USERNAME  机器人账号完整用户名
#   HARBOR_PASSWORD  对应密码 / robot token
#
# 注意：Harbor 的 /service/token 对匿名请求和错误凭据也会返回 HTTP 200，
# 只是 JWT 的 access 里 actions 为空。因此这里先用 /api/v2.0/users/current
# 做认证校验，再区分“认证失败”和“没有 push 权限”。
set -euo pipefail

: "${REGISTRY:?REGISTRY is required}"
: "${IMAGE_PREFIX:?IMAGE_PREFIX is required}"

if [ -z "${HARBOR_USERNAME:-}" ] || [ -z "${HARBOR_PASSWORD:-}" ]; then
  echo "::error::缺少 HARBOR_USERNAME / HARBOR_PASSWORD。"
  echo "::error::请在 Settings -> Secrets and variables -> Actions -> Repository secrets 中配置。"
  echo "::error::项目级机器人完整用户名为 robot\$<项目名>+<机器人名>；系统级为 robot\$<机器人名>。"
  exit 1
fi

api="https://${REGISTRY}/api/v2.0"
project="${IMAGE_PREFIX%%/*}"
images=(
  "${IMAGE_PREFIX}-app"
  "${IMAGE_PREFIX}-docreader"
  "${IMAGE_PREFIX}-ui"
  "${IMAGE_PREFIX}-sandbox"
)

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

# (0) 认证校验：/users/current 匿名访问返回 401，合法凭据才返回 200。
auth_code=$(curl -sS -o "${tmpdir}/current.json" -w '%{http_code}' \
  -u "${HARBOR_USERNAME}:${HARBOR_PASSWORD}" \
  "${api}/users/current" || echo 000)

if [ "${auth_code}" = "200" ]; then
  current_user=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("username",""))' "${tmpdir}/current.json" 2>/dev/null || true)
  echo "认证通过（用户），当前账号：${current_user:-<unknown>}"
elif [ "${auth_code}" = "412" ] && grep -q 'security context: robot' "${tmpdir}/current.json" 2>/dev/null; then
  # Harbor 对机器人账号访问 /users/current 会返回 412（机器人没有 current user），
  # 这是认证成功的正常表现，不是错误。
  echo "认证通过（机器人账号）。"
elif [ "${auth_code}" = "401" ]; then
  echo "::error::Harbor 认证失败（HTTP 401）：HARBOR_USERNAME / HARBOR_PASSWORD 不正确。"
  echo "::error::项目级机器人用户名格式为 robot\$<项目名>+<机器人名>，例如 robot\$library+robot2；"
  echo "::error::系统级机器人为 robot\$<机器人名>。请从 Harbor「机器人账户」页面复制完整用户名。"
  echo "::error::响应：$(head -c 300 "${tmpdir}/current.json" 2>/dev/null || true)"
  exit 1
else
  echo "::error::Harbor 认证检查异常（HTTP ${auth_code}）。"
  echo "::error::响应：$(head -c 300 "${tmpdir}/current.json" 2>/dev/null || true)"
  exit 1
fi

# (1) 项目存在，且不是代理缓存项目（Harbor 禁止向 proxy cache 项目推送）。
proj_code=$(curl -sS -o "${tmpdir}/project.json" -w '%{http_code}' \
  -u "${HARBOR_USERNAME}:${HARBOR_PASSWORD}" \
  "${api}/projects/${project}" || echo 000)
if [ "${proj_code}" != "200" ]; then
  echo "::error::无法读取 Harbor 项目 ${project}（HTTP ${proj_code}），请检查项目名与机器人权限。"
  echo "::error::响应：$(head -c 300 "${tmpdir}/project.json" 2>/dev/null || true)"
  exit 1
fi
registry_id=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("registry_id") or 0)' "${tmpdir}/project.json" 2>/dev/null || echo 0)
if [ "${registry_id}" != "0" ]; then
  echo "::error::Harbor 项目 ${project} 是代理缓存项目（registry_id=${registry_id}），禁止推送。"
  exit 1
fi

for image in "${images[@]}"; do
  echo "检查 ${REGISTRY}/${image}"

  # (2) 取 registry token 并解析 access。
  token_code=$(curl -sS -o "${tmpdir}/token.json" -w '%{http_code}' \
    -u "${HARBOR_USERNAME}:${HARBOR_PASSWORD}" \
    "https://${REGISTRY}/service/token?service=harbor-registry&scope=repository:${image}:pull,push" \
    || echo 000)
  if [ "${token_code}" != "200" ]; then
    echo "::error::获取 ${image} 的 registry token 失败（HTTP ${token_code}）。"
    exit 1
  fi

  if ! python3 - "${image}" "${tmpdir}/token.json" <<'PY'
import base64
import json
import sys

image, token_file = sys.argv[1], sys.argv[2]
data = json.load(open(token_file))
token = data.get("token") or data.get("access_token") or ""
parts = token.split(".")
if len(parts) != 3:
    print("  <无法解析 token>")
    sys.exit(2)

payload = parts[1] + "=" * (-len(parts[1]) % 4)
access = json.loads(base64.urlsafe_b64decode(payload)).get("access", [])
actions = set()
for entry in access:
    actions.update(entry.get("actions") or [])
print("  token access:", json.dumps(access, ensure_ascii=False))
print("  授予的权限:", " ".join(sorted(actions)) or "<空>")
sys.exit(0 if "push" in actions else 2)
PY
  then
    echo "::error::账号对 ${REGISTRY}/${image} 没有 push 权限（token 的 actions 中不含 push）。"
    echo "::error::请检查机器人权限的“仓库范围”："
    echo "::error::  1) 推荐选择“所有仓库”。按仓库授权时，尚未创建的 weknora-* 仓库无法被选中；"
    echo "::error::  2) 或把 ${image} 加入机器人可访问仓库，并勾选 Pull/Push。"
    exit 1
  fi
done

echo "Harbor 推送前置校验通过。"