# 路由 App 覆盖地区文件

结论：不适用，不需要上传。

听写复习本不是导航、地图、公交、骑行、步行、驾车或路线规划类 App，也没有使用位置来向 Apple Maps 或其他 App 提供路线信息。因此不应上传 Routing App Coverage File。

App Store Connect 中的“路由 App 覆盖地区文件”只适用于使用位置提供路线信息的 routing app。Apple 文档说明：如果 App 使用位置提供路线信息，提交审核前必须提供地理覆盖地区文件。

本 App 的处理建议：

- App Store Connect 中不要上传路由覆盖地区文件。
- Xcode 工程中不要把 App 配置成 routing app。
- 如果 App Store Connect 要求上传该文件，优先检查 App 的类别、Info.plist、Capabilities 或文档类型配置，确认是否误开启了 routing app 相关设置。

参考：

- https://developer.apple.com/documentation/appstoreconnectapi/routing-app-coverages
