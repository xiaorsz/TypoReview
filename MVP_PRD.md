# 错字复习 App MVP 方案

## 1. 产品定位

这是一个面向低龄孩子家庭场景的错字/单词复习 App。

核心目标：

- 家长能快速录入孩子当天写错的汉字、词语、英文单词
- 系统按艾宾浩斯遗忘曲线安排复习
- 孩子在线下纸上书写
- 家长在 App 内手动判定正确或错误
- 系统根据结果自动安排下一次复习

第一版不做手写识别，不做自动判卷，不做复杂账号系统。

产品核心闭环：

`录入错项 -> 到期提醒 -> 出题复习 -> 家长判定对错 -> 调整复习阶段 -> 再次提醒`

## 2. MVP 范围

### 必做

- 错字/词语/英文单词录入
- 今日待复习列表
- 复习流程页
- 家长手动判定正确/不正确
- 按遗忘曲线推进或回退
- 本地通知提醒
- 题库浏览和搜索
- 基础统计

### 暂不做

- OCR 拍照录入
- 手写识别
- AI 出题
- 云同步
- 多设备账号系统
- 班级/老师功能
- 游戏化体系

## 3. 目标用户

### 主要用户

- 小学生家庭
- 以家长陪练为主
- 重点场景是语文错字、词语听写、英语单词拼写

### 使用角色

- 家长：录入、提醒设置、陪练判定、查看统计
- 孩子：看题、在线下纸上书写、完成每日复习

## 4. 核心使用场景

### 场景 A：当天错题录入

孩子做完作业或听写后，家长把写错的汉字、词语或英文单词录入 App。

### 场景 B：每日复习

到了提醒时间，家长打开 App，陪孩子做 5 到 10 分钟复习。孩子看题后在纸上写，家长判定对错。

### 场景 C：阶段复盘

家长查看最近总错的内容，知道哪些内容要继续重点练。

## 5. 复习机制

## 5.1 设计原则

- 前期复习密，后期间隔逐渐拉长
- 答对就进入下一阶段
- 答错就回退并当天强化
- 规则要足够简单，让家长能理解

## 5.2 艾宾浩斯阶段

建议采用以下阶段：

| 阶段 | 间隔 |
|---|---|
| 0 | 新录入，当天待复习 |
| 1 | 20 分钟后 |
| 2 | 1 天后 |
| 3 | 2 天后 |
| 4 | 4 天后 |
| 5 | 7 天后 |
| 6 | 15 天后 |
| 7 | 30 天后 |

说明：

- 如果一天内不适合安排 20 分钟后的提醒，也可以把阶段 1 合并到当天的“稍后再练”
- 第一版可以允许系统把同一天的任务自动并到同一个复习列表中

## 5.3 结果处理规则

### 正确

- 当前项目进入下一阶段
- 根据下一阶段间隔生成 `nextReviewAt`

### 不正确

- 当次记录为错误
- 正式阶段回退 1 级
- 如果当前已经是最低阶段，则保持最低阶段
- 下一次复习最早从第二天开始，不在当天重复出现
- 连续错误 2 次以上时，标记为重点复习

## 5.4 任务生成规则

每天打开 App 时，系统生成正式复习任务：

- 正式复习：`nextReviewAt <= 当前时间`

每日上限建议：

- 默认 15 题
- 家长可设置 10 / 15 / 20 题

## 6. 题目与判定方式

## 6.1 汉字/词语

出题方式：

- 看拼音写词语
- 看解释写词语
- 看例句填空

作答方式：

- 孩子在线下纸上书写
- 家长点击“正确”或“不正确”

## 6.2 英文单词

出题方式：

- 看中文写英文
- 看英文释义写单词
- 看例句补全

作答方式：

- 孩子在线下纸上书写
- 家长点击“正确”或“不正确”

## 6.3 判定逻辑

第一版不让系统自动识别内容。

判定流程：

1. App 出题
2. 孩子在纸上写
3. 家长查看是否正确
4. 在 App 中点击：
   - 正确
   - 不正确

这样能显著降低第一版复杂度，也避免手写识别误判。

## 7. 页面结构

## 7.1 首页

展示内容：

- 今天待复习数量
- 稍后再练数量
- 今日已完成数量
- 入口按钮：开始复习
- 快捷入口：新增错题

## 7.2 新增页

字段建议：

- 类型：汉字 / 词语 / 单词
- 正确内容
- 题目提示
- 备注
- 来源

交互要求：

- 10 秒内可以完成一条录入
- 保存后默认加入当天待复习

## 7.3 今日复习页

每次展示 1 题：

- 题目提示
- “我写好了”按钮
- 家长判定按钮：
  - 正确
  - 不正确

辅助信息：

- 当前进度，如 `3 / 12`
- 当前题目类型

## 7.4 结果页

展示：

- 今日完成总数
- 正确数
- 错误数
- 哪些项目进入下一阶段
- 哪些项目被安排稍后再练

## 7.5 题库页

支持：

- 查看全部项目
- 搜索
- 按类型筛选
- 按状态筛选：待复习 / 重点复习 / 已掌握

## 7.6 详情页

展示：

- 项目内容
- 来源和备注
- 当前阶段
- 下次复习时间
- 最近复习记录

## 7.7 设置页

支持：

- 每日提醒时间
- 每日题量上限
- 孩子姓名

## 8. 数据模型

## 8.1 ReviewItem

用于存储每个错字/词语/单词。

建议字段：

- `id`
- `type`
- `content`
- `prompt`
- `note`
- `source`
- `stage`
- `nextReviewAt`
- `lastReviewedAt`
- `consecutiveCorrectCount`
- `consecutiveWrongCount`
- `isPriority`
- `createdAt`
- `updatedAt`

## 8.2 ReviewRecord

用于记录每次复习结果。

建议字段：

- `id`
- `itemId`
- `reviewedAt`
- `result`
- `mode`
- `oldStage`
- `newStage`
- `note`

其中：

- `result`：correct / wrong
- `mode`：scheduled / retry

## 8.3 AppSettings

建议字段：

- `id`
- `childName`
- `dailyLimit`
- `remindHour`
- `remindMinute`
- `retryEnabled`

## 9. 状态设计

每个项目可以有以下业务状态：

- `待复习`
- `稍后再练`
- `重点复习`
- `已掌握`

判定建议：

- 阶段达到 7 且最近一次答对，可视为已掌握
- 连续错误次数 >= 2，可标为重点复习

## 10. 核心伪代码

```swift
let intervals: [TimeInterval] = [
    0,
    20 * 60,
    24 * 60 * 60,
    2 * 24 * 60 * 60,
    4 * 24 * 60 * 60,
    7 * 24 * 60 * 60,
    15 * 24 * 60 * 60,
    30 * 24 * 60 * 60
]

func handleReviewResult(item: ReviewItem, result: ReviewResult, now: Date) {
    let oldStage = item.stage

    if result == .correct {
        item.consecutiveCorrectCount += 1
        item.consecutiveWrongCount = 0
        item.stage = min(item.stage + 1, intervals.count - 1)
        item.nextReviewAt = now.addingTimeInterval(intervals[item.stage])
        item.isPriority = false
    } else {
        item.consecutiveWrongCount += 1
        item.consecutiveCorrectCount = 0
        item.stage = max(item.stage - 1, 1)
        item.nextReviewAt = now.addingTimeInterval(intervals[item.stage])
        item.isPriority = item.consecutiveWrongCount >= 2
        enqueueRetryForToday(item)
    }

    saveReviewRecord(
        itemId: item.id,
        reviewedAt: now,
        result: result,
        mode: .scheduled,
        oldStage: oldStage,
        newStage: item.stage
    )
}
```

## 11. 技术建议

第一版建议使用：

- SwiftUI
- SwiftData
- UserNotifications
- MVVM

原因：

- 本地单机版足够支撑 MVP
- 开发速度快
- 后续可以平滑扩展同步能力

## 12. 开发顺序

建议按以下顺序实现：

1. 建立数据模型
2. 实现复习调度和阶段推进逻辑
3. 完成新增页和题库页
4. 完成今日复习流程
5. 完成结果页和基础统计
6. 接入本地通知
7. 优化首页和设置页

## 13. 成功标准

MVP 是否成立，可以看以下指标：

- 家长是否能坚持连续录入 7 天
- 孩子是否能连续完成每日复习 7 天
- 单次复习是否能控制在 5 到 10 分钟
- 错误内容在两周内是否明显减少

## 14. 下一步建议

如果继续推进，下一阶段建议输出：

- 信息架构图
- 页面线框图
- SwiftData 模型代码
- SwiftUI 页面骨架
- 复习调度服务实现
