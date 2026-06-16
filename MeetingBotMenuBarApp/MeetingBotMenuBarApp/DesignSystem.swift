import AppKit
import SwiftUI

// 统一的设计 token：间距、圆角、品牌色、语义状态色、会议类型样式。
// 目的是收敛此前散落各处的魔法数字和系统默认配色，建立一致的视觉语言。

enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
}

enum CornerRadius {
    static let small: CGFloat = 8
    static let medium: CGFloat = 10
    static let large: CGFloat = 12
}

private func dynamicColor(
    light: (CGFloat, CGFloat, CGFloat),
    dark: (CGFloat, CGFloat, CGFloat)
) -> Color {
    let nsColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let rgb = isDark ? dark : light
        return NSColor(
            srgbRed: rgb.0 / 255,
            green: rgb.1 / 255,
            blue: rgb.2 / 255,
            alpha: 1
        )
    }
    return Color(nsColor: nsColor)
}

enum AppColorTheme: String, CaseIterable, Identifiable {
    case blue
    case green
    case gray

    static let storageKey = "appColorTheme"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blue:
            return "蓝"
        case .green:
            return "绿"
        case .gray:
            return "灰"
        }
    }

    var accentColor: Color {
        dynamicColor(light: lightAccent, dark: darkAccent)
    }

    private var lightAccent: (CGFloat, CGFloat, CGFloat) {
        switch self {
        case .blue:
            return (25, 96, 166)
        case .green:
            return (15, 110, 86)
        case .gray:
            return (88, 94, 104)
        }
    }

    private var darkAccent: (CGFloat, CGFloat, CGFloat) {
        switch self {
        case .blue:
            return (74, 145, 222)
        case .green:
            return (29, 158, 117)
        case .gray:
            return (156, 164, 176)
        }
    }

    static var current: AppColorTheme {
        let rawValue = UserDefaults.standard.string(forKey: storageKey)
            ?? AppColorTheme.green.rawValue
        return AppColorTheme(rawValue: rawValue) ?? .green
    }
}

extension Color {
    // 品牌主强调色。明亮模式偏深沉稳，暗色模式提亮以保证对比度。
    static var brandAccent: Color { AppColorTheme.current.accentColor }

    // 语义状态色，全局统一处理中/完成/错误的视觉。
    static let statusProcessing = dynamicColor(
        light: (186, 117, 23),
        dark: (239, 159, 39)
    )
    static let statusDone = dynamicColor(
        light: (99, 153, 34),
        dark: (151, 196, 89)
    )
    static let statusError = dynamicColor(
        light: (226, 75, 74),
        dark: (240, 149, 149)
    )

    // 选中态等的柔色填充。
    static var brandAccentSoft: Color { brandAccent.opacity(0.12) }
}

// 会议类型 → 视觉锚点。颜色统一用品牌青绿，靠 SF Symbol 区分类型，
// 保持列表视觉一致、不杂乱。
enum MeetingTypeStyle {
    static func symbol(for meetingType: String) -> String {
        switch meetingType {
        case "general_meeting": return "bubble.left.and.bubble.right"
        case "research_discussion": return "atom"
        case "project_progress": return "chart.bar"
        case "expert_consultation": return "checkmark.seal"
        case "management_meeting": return "briefcase"
        case "interview_summary": return "quote.bubble"
        case "parent_teacher_meeting": return "graduationcap"
        case "legal_communication": return "building.columns"
        case "sales_conversion": return "chart.line.uptrend.xyaxis"
        case "customer_success": return "hand.thumbsup"
        case "product_development": return "hammer"
        case "product_review": return "checklist"
        case "recruitment_interview": return "person.badge.plus"
        case "training_workshop": return "lightbulb"
        default: return "bubble.left.and.bubble.right"
        }
    }

    // 列表项元信息里展示的简短类型名；未知（自定义模板）返回空，调用方据此省略。
    static func shortName(for meetingType: String) -> String {
        switch meetingType {
        case "general_meeting": return "通用"
        case "research_discussion": return "科研讨论"
        case "project_progress": return "项目推进"
        case "expert_consultation": return "专家评审"
        case "management_meeting": return "管理工作"
        case "interview_summary": return "访谈座谈"
        case "parent_teacher_meeting": return "家校沟通"
        case "legal_communication": return "法律合规"
        case "sales_conversion": return "销售商机"
        case "customer_success": return "客户成功"
        case "product_development": return "产品研发"
        case "product_review": return "产品评审"
        case "recruitment_interview": return "招聘面试"
        case "training_workshop": return "培训工作坊"
        default: return ""
        }
    }
}
