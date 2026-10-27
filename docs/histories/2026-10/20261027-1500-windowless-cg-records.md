# 无窗口启动的CG辅助记录判定

用户要求顺序实机复测并修复失败，不放宽停止规则、不重复执行输入。

Numbers关闭打开面板后AX成功返回空窗口集合，但CG仍保留菜单、工具提示及隐藏面板记录。原逻辑将同PID任意CG记录都当作窗口，阻断既有一次后台reopen路径。

新增OpeningWindowAbsence：AX明确为空后，仅排除未显示且SLSCopySpacesForWindows明确返回空集合的CG记录。可见窗口、非当前Space窗口、未知元数据、AX失败、取消和迟到结果均不触发reopen。原3秒等待与200ms复查、身份校验、挂起禁止重放保持。

测试覆盖元数据分类、空间查询超时/取消、Service成功绑定和挂起跨别名不重开。实机验收需使用新pin签名App另行完成。

验证：定向31项初跑通过，新增成功Service链路后完整625项XCTest（8项live跳过）通过；Swift Testing初跑3个计时测试失败，独立11项预览复查通过，完整复查68项通过。未更改计时规则。新增文件SwiftFormat/SwiftLint通过，文档检查通过。
