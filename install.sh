#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
app_name="REAI Music Controller.app"
install_dir="${HOME}/Applications"
installed_app="${install_dir}/${app_name}"
launch_agents_dir="${HOME}/Library/LaunchAgents"
launch_agent_name="com.shougongchuan.reai-music-controller.plist"
launch_agent_path="${launch_agents_dir}/${launch_agent_name}"
launch_domain="gui/$(id -u)"

"${script_dir}/build.sh"
mkdir -p "${install_dir}" "${launch_agents_dir}"
/usr/bin/osascript -e 'tell application id "com.shougongchuan.reai-music-controller" to quit' 2>/dev/null || true
ditto "${script_dir}/${app_name}" "${installed_app}"
install -m 0644 "${script_dir}/${launch_agent_name}" "${launch_agent_path}"

launchctl bootout "${launch_domain}" "${launch_agent_path}" 2>/dev/null || true
launchctl bootstrap "${launch_domain}" "${launch_agent_path}"

echo "已安装: ${installed_app}"
echo "已启用登录启动: ${launch_agent_path}"
echo "首次语音对话请允许“麦克风”和“语音识别”；音乐控制仍需 Apple Music 自动化权限。"
