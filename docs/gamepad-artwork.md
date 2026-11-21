# 手柄实机素材与标定

## 使用规则

- PlayStation 全系列（DualShock 3、DualShock 4、DualSense）统一使用 PS5 DualSense 外观；真实输入映射仍按实际型号。
- Xbox 360、Xbox One、Xbox Series 统一使用 Xbox Series 外观；真实输入映射仍按实际型号。
- 罗技 F310、Extreme 3D Pro 与飞智冰原狼 4 使用各自标准版外观；Extreme 3D Pro 使用飞行摇杆专用输入与指示布局。
- 当前仅用于私有仓库和本机应用。厂商图片的公开再分发授权未据此视为已获批准；任何公开发布前必须重新审查素材条款。
- 所有图片离线打包，不在运行时请求远程 URL。现有图片保持原比例，不做拉伸或透视变形。

## 素材来源与校验

| 资源 | 型号/外观 | 来源 | 入库尺寸 | SHA-256 |
|---|---|---|---|---|
| `dualsense.png` | PS5 DualSense 白黑标准版 | [PlayStation Direct](https://direct.playstation.com/en-us/buy-accessories/dualsense-wireless-controller-white-for-ps5-pc-mac-mobile)，原始资源 `2025-dualsense-ps5-controller-white-accessory-front-hero-1` | 1600×900 | `b098c475ba263afe84861f1fb543509c4d41db01f8653b4d8403b7cc66d25c7b` |
| `xbox-series.png` | Xbox Wireless Controller Carbon Black | [Xbox Gallery 0_4](https://assets.xboxservices.com/assets/fa/b8/fab86afd-63d6-45a9-862f-798e5e45cda2.jpg?n=111101_Gallery-0_4_1350x759.jpg) | 1023×736 | `da52b7f19b1b047511eb20cee82c9221fc5e012eda8cc697cc31234c4a3b042b` |
| `f310.png` | Logitech F310 黑蓝标准版 | [Logitech F310](https://www.logitechg.com/en-us/shop/p/f310-gamepad)，原始资源 `f310-gallery-1.png` | 755×556 | `d10490917e3125deeff5fadc9dc5ba7421bdc4557a3fbc900cf9f146ad0d0253` |
| `direwolf4.png` | 飞智冰原狼 4 标准版 | [Flydigi Russia 产品页](https://flydigi.ru/catalog/flydigi-direwolf-4.html)，原始资源 `01_direwolf_4_1600_1000_150.webp` | 1600×1000 | `311e435fc523f33bd16f46bffb4fe41c479119cad1c283611e47f29aef4d1456` |
| `extreme3dpro.png` | Logitech Extreme 3D Pro 飞行摇杆 | [Logitech Extreme 3D Pro](https://www.logitechg.com/en-us/shop/p/extreme-3d-pro-joystick)，原始资源 `3dpro-gallery-1.png` | 1510×1112 | `e1db5800a95963e771f8606b175579a4eebee181ab32cb8b52fb12956c976dc3` |

Xbox 图片只做边缘白底透明化与透明边界裁切；手柄本体、按钮、颜色和标志未重绘。其他图片仅做格式转换或保持原始文件。所有入库 PNG 均已确认带 alpha 通道。

## 标定方法与主要锚点

使用 `.build/grid-overlay.swift` 在原图上叠加 50/100 像素网格，按原始像素记录控件边界。生产坐标表位于 `Sources/GHDS/Views/GamepadArtwork/GamepadArtwork.swift`，渲染时统一使用 `GamepadArtworkSpec.region(_:in:)` 的 aspect-fit 变换。

| 资源 | 左摇杆井（x,y,w,h） | 右摇杆井（x,y,w,h） | 方向键区（x,y,w,h） | 触控板 / 中央标志区（x,y,w,h） |
|---|---|---|---|---|
| DualSense | 610,400,125,125 | 875,400,125,125 | 475,275,155,155 | 640,200,320,180 |
| Xbox Series | 190,135,140,145 | 565,290,145,150 | 310,295,145,150 | 465,75,90,90 |
| F310 | 210,290,135,140 | 405,290,135,140 | 110,165,145,145 | 340,185,80,65 |
| Direwolf 4 | 360,150,170,190 | 745,310,185,220 | 450,340,180,185 | 720,95,100,100 |
| Extreme 3D Pro | 300,0,400,600（方向指示区） | 300,0,400,600（Z 扭转指示区） | 400,120,120,140 | 1120,760,120,200（Slider） |

摇杆帽使用独立 `leftStickCap` / `rightStickCap` 区域。可移动行程逐款由「井区域与帽区域之差」计算，不手写统一行程；`GamepadArtworkTests` 对 aspect-fit 留白、零值回中、超量程钳制和系列资源映射做回归。
