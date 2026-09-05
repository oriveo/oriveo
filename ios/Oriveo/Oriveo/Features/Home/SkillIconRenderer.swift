import SwiftUI

struct SkillIconRenderer: View {
    let icon: String
    let tintColor: Color
    let size: CGFloat

    var body: some View {
        if let symbolName = SkillIconMapping.symbolName(for: icon) {
            Image(systemName: symbolName)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(tintColor)
                .symbolRenderingMode(.hierarchical)
                .frame(width: size * 1.4, height: size * 1.4)
        } else {
            Text(icon)
                .font(.system(size: size + 4))
                .frame(width: size * 1.4, height: size * 1.4)
        }
    }
}


enum SkillIconMapping {
    static func symbolName(for emoji: String) -> String? {
        let normalized = emoji.replacingOccurrences(of: "\u{FE0F}", with: "")
        return emojiToSymbol[emoji] ?? emojiToSymbol[normalized]
    }

    private static let emojiToSymbol: [String: String] = [
        "✍️": "square.and.pencil",
        "✍": "square.and.pencil",
        "✏️": "pencil",
        "✏": "pencil",
        "🖊️": "pencil",
        "🖋️": "pencil.tip",
        "📝": "square.and.pencil",
        "📄": "doc",
        "📃": "doc.text",
        "📑": "doc.text.fill",
        "📜": "scroll",
        "🗒️": "note.text",

        "✅": "checkmark.seal.fill",
        "✔️": "checkmark",
        "✔": "checkmark",
        "❌": "xmark.circle.fill",
        "🔍": "magnifyingglass",
        "🔎": "magnifyingglass.circle",
        "📋": "list.bullet.clipboard",
        "☑️": "checkmark.square.fill",

        "🌐": "globe",
        "🌍": "globe.europe.africa",
        "🌎": "globe.americas",
        "🌏": "globe.asia.australia",
        "🗺️": "map",
        "🗺": "map",
        "🔤": "textformat.abc",
        "🔡": "textformat.abc.dottedunderline",
        "🔠": "textformat",

        "💻": "laptopcomputer",
        "🖥️": "desktopcomputer",
        "🖥": "desktopcomputer",
        "⌨️": "keyboard",
        "⌨": "keyboard",
        "🗄️": "cylinder.split.1x2",
        "🗄": "cylinder.split.1x2",
        "💾": "externaldrive",
        "💿": "opticaldisc",
        "📀": "opticaldisc.fill",
        "🐛": "ant",
        "🤖": "cpu",
        "⚙️": "gearshape.fill",
        "⚙": "gearshape.fill",
        "🔧": "wrench.adjustable",
        "🔨": "hammer",
        "🛠️": "wrench.and.screwdriver",
        "🛠": "wrench.and.screwdriver",
        "🧰": "shippingbox",

        "📊": "chart.bar.fill",
        "📈": "chart.line.uptrend.xyaxis",
        "📉": "chart.line.downtrend.xyaxis",

        "💡": "lightbulb.fill",
        "✨": "sparkles",
        "🎨": "paintpalette.fill",
        "🎯": "target",
        "🧠": "brain.head.profile",
        "🌟": "star.fill",
        "⭐": "star.fill",
        "⭐️": "star.fill",

        "🎓": "graduationcap.fill",
        "📚": "books.vertical.fill",
        "📖": "book",
        "📕": "book.closed.fill",
        "📗": "book.closed.fill",
        "📘": "book.closed.fill",
        "📙": "book.closed.fill",
        "🏫": "building.columns.fill",

        "💼": "briefcase.fill",
        "💰": "dollarsign.circle.fill",
        "💵": "banknote.fill",
        "💸": "dollarsign.arrow.circlepath",
        "💹": "chart.line.uptrend.xyaxis",
        "🧾": "doc.plaintext",

        "📅": "calendar",
        "📆": "calendar",
        "🗓️": "calendar",
        "🗓": "calendar",
        "⏰": "alarm.fill",
        "⏱️": "stopwatch.fill",
        "⏱": "stopwatch.fill",
        "⏲️": "timer",
        "🕐": "clock",
        "⌛": "hourglass",
        "⏳": "hourglass.bottomhalf.filled",

        "📧": "envelope.fill",
        "📨": "envelope.open.fill",
        "📩": "envelope.badge",
        "✉️": "envelope",
        "✉": "envelope",
        "📞": "phone.fill",
        "📱": "iphone",
        "💬": "bubble.left.and.bubble.right.fill",
        "💭": "bubble.left",
        "🗨️": "bubble",
        "🗨": "bubble",
        "🗯️": "exclamationmark.bubble",
        "🗣️": "person.wave.2.fill",
        "🗣": "person.wave.2.fill",

        "🔐": "lock.shield.fill",
        "🔒": "lock.fill",
        "🔓": "lock.open.fill",
        "🛡️": "shield.fill",
        "🛡": "shield.fill",
        "🔑": "key.fill",
        "🗝️": "key.viewfinder",

        "🏥": "cross.case.fill",
        "💊": "pill.fill",
        "❤️": "heart.fill",
        "❤": "heart.fill",
        "🩺": "stethoscope",

        "✈️": "airplane",
        "✈": "airplane",
        "🚗": "car.fill",
        "🚕": "car.fill",
        "🏠": "house.fill",
        "🏡": "house.fill",
        "🏢": "building.2.fill",
        "🏨": "building.fill",
        "🚀": "airplane.departure",

        "📁": "folder.fill",
        "📂": "folder.fill.badge.plus",
        "🗂️": "folder.badge.gearshape",
        "🗂": "folder.badge.gearshape",
        "📌": "pin.fill",
        "📍": "mappin",
        "🔖": "bookmark.fill",
        "🏷️": "tag.fill",
        "🏷": "tag.fill",

        "🎬": "film.fill",
        "🎥": "video.fill",
        "📽️": "film",
        "📽": "film",
        "🎵": "music.note",
        "🎶": "music.note.list",
        "🎤": "mic.fill",
        "🎧": "headphones",
        "📷": "camera.fill",
        "📸": "camera.viewfinder",
        "📹": "video.fill",
        "📺": "tv.fill",
        "🎮": "gamecontroller.fill",

        "🍽️": "fork.knife",
        "🍽": "fork.knife",
        "☕": "cup.and.saucer.fill",
        "🍵": "mug.fill",
        "🍳": "frying.pan",

        "⚖️": "scale.3d",
        "⚖": "scale.3d",

        "🌿": "leaf.fill",
        "🍃": "leaf",
        "🌳": "tree.fill",
        "🌲": "tree",
        "☀️": "sun.max.fill",
        "☀": "sun.max.fill",
        "🌙": "moon.fill",
        "🌧️": "cloud.rain.fill",
        "⛈️": "cloud.bolt.rain.fill",
        "❄️": "snowflake",
        "❄": "snowflake",
        "🔥": "flame.fill",
        "💧": "drop.fill",

        "🧮": "function",
        "➕": "plus",
        "➖": "minus",
        "✖️": "multiply",
        "✖": "multiply",
        "➗": "divide",
        "🔢": "number",
        "📐": "ruler",
        "📏": "ruler.fill",

        "👤": "person.fill",
        "👥": "person.2.fill",
        "🧑‍💻": "person.crop.circle.badge.checkmark",
        "👨‍🏫": "person.bust",
        "👩‍🏫": "person.bust",
        "👨‍🍳": "fork.knife.circle",
        "👨‍⚕️": "stethoscope.circle",
        "🧑‍🎨": "paintpalette",

        "📰": "newspaper.fill",
        "🎁": "gift.fill",
        "🎉": "party.popper.fill",
        "🎊": "party.popper",
        "🏆": "trophy.fill",
        "🥇": "medal.fill",
        "🎖️": "medal.fill",
        "🎖": "medal.fill",
        "🚦": "exclamationmark.triangle.fill",
        "⚠️": "exclamationmark.triangle.fill",
        "⚠": "exclamationmark.triangle.fill",
        "❓": "questionmark.circle",
        "❔": "questionmark",
        "❗": "exclamationmark.circle.fill",
        "❕": "exclamationmark",
        "ℹ️": "info.circle.fill",
        "ℹ": "info.circle.fill",
    ]
}
