# Shared smoke environment preflight. Source this before invoking any phase.
for idc_tool_dir in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/.npm-global/bin"; do
  [ -d "$idc_tool_dir" ] || continue
  case ":$PATH:" in
    *":$idc_tool_dir:"*) ;;
    *) PATH="$idc_tool_dir:$PATH" ;;
  esac
done
export PATH
unset idc_tool_dir
