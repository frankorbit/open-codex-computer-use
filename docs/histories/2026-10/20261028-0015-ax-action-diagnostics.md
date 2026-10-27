# 普通 AX 动作发送诊断

用户要求继续按顺序真机测试，遇到失败先核实并修复，不重复已发送操作、不放宽停止规则。提醒事项详情点击返回成功但未观察到编辑器，现有日志没有普通 AX 输入阶段，无法确认具体调用。

## 变更

普通 AX 动作及 secondary action 在实际调用前后记录动作类别、原始目标索引、候选来源、role 白名单、attempt 和 AX 返回码。自定义动作和角色均折叠为 other，不记录控件内容。MCP 为 secondary action 建立与其他输入相同的诊断关联；对异常及业务返回保持原处理。

输入次数、候选顺序、AX/鼠标选择、等待、权限、取消和错误停止逻辑不变。成功返回仍是效果未核实，不能据此报告任务完成。

## 验证与边界

新增 helper 及真实 MCP→service 输入入口回归；Web owner-guard 验证 secondary action 仅一次分发，失败不继续脚本。完整测试结果与签名 App 验收随后记录。

本提交只修诊断缺口，不宣称已经修复提醒事项详情未打开。Codex 独立样本出现错误返回但实际打开，不能推断其内部输入实现。原失败目标不重放，诊断制品以新的独立目标验证。

定向34项通过；原生完整串行680 XCTest（8跳过）+68 Swift Testing通过。新增文件SwiftFormat/SwiftLint strict通过，现有Service/MCP lint零新增违规。Web Runtime269项通过，含secondary成功/失败owner-guard。静态review确认输入路线/次数和原错误传播不变；签名App实机诊断待验证。
