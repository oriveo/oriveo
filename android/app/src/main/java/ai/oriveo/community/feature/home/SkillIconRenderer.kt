package ai.oriveo.community.feature.home

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Construction
import androidx.compose.material.icons.filled.EmojiEvents
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.FolderShared
import androidx.compose.material.icons.filled.Forum
import androidx.compose.material.icons.filled.Gavel
import androidx.compose.material.icons.filled.Headphones
import androidx.compose.material.icons.filled.Hotel
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Lightbulb
import androidx.compose.material.icons.filled.LocalCafe
import androidx.compose.material.icons.filled.LocalFireDepartment
import androidx.compose.material.icons.filled.LocalHospital
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.LockOpen
import androidx.compose.material.icons.filled.Medication
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MonetizationOn
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Newspaper
import androidx.compose.material.icons.filled.Palette
import androidx.compose.material.icons.filled.Phone
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.School
import androidx.compose.material.icons.filled.Security
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material.icons.automirrored.outlined.Article
import androidx.compose.material.icons.automirrored.outlined.HelpOutline
import androidx.compose.material.icons.automirrored.outlined.MenuBook
import androidx.compose.material.icons.automirrored.outlined.Notes
import androidx.compose.material.icons.automirrored.outlined.TrendingDown
import androidx.compose.material.icons.automirrored.outlined.TrendingUp
import androidx.compose.material.icons.outlined.AcUnit
import androidx.compose.material.icons.outlined.Calculate
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.CameraAlt
import androidx.compose.material.icons.outlined.Cancel
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.CheckBox
import androidx.compose.material.icons.outlined.Code
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.DesktopWindows
import androidx.compose.material.icons.outlined.Devices
import androidx.compose.material.icons.outlined.DirectionsCar
import androidx.compose.material.icons.outlined.Drafts
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Email
import androidx.compose.material.icons.outlined.Equalizer
import androidx.compose.material.icons.outlined.Error
import androidx.compose.material.icons.outlined.Flight
import androidx.compose.material.icons.outlined.HourglassEmpty
import androidx.compose.material.icons.outlined.HourglassFull
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Keyboard
import androidx.compose.material.icons.outlined.LaptopMac
import androidx.compose.material.icons.outlined.Mail
import androidx.compose.material.icons.outlined.Map
import androidx.compose.material.icons.outlined.MarkEmailRead
import androidx.compose.material.icons.outlined.NightsStay
import androidx.compose.material.icons.outlined.Numbers
import androidx.compose.material.icons.outlined.Park
import androidx.compose.material.icons.outlined.Person
import androidx.compose.material.icons.outlined.Psychology
import androidx.compose.material.icons.outlined.Public
import androidx.compose.material.icons.outlined.QuestionMark
import androidx.compose.material.icons.outlined.Restaurant
import androidx.compose.material.icons.outlined.RocketLaunch
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.SmartToy
import androidx.compose.material.icons.outlined.SportsEsports
import androidx.compose.material.icons.outlined.SportsScore
import androidx.compose.material.icons.outlined.Square
import androidx.compose.material.icons.outlined.Straighten
import androidx.compose.material.icons.outlined.Tag
import androidx.compose.material.icons.outlined.TextFields
import androidx.compose.material.icons.outlined.Timer
import androidx.compose.material.icons.outlined.WbSunny
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.sp

@Composable
internal fun SkillIcon(
    icon: String,
    tintColor: Color,
    size: Dp,
    modifier: Modifier = Modifier,
) {
    val symbol = SkillIconMapping.iconFor(icon)
    Box(
        modifier = modifier.size(size * 1.4f),
        contentAlignment = Alignment.Center,
    ) {
        if (symbol != null) {
            Icon(
                imageVector = symbol,
                contentDescription = null,
                tint = tintColor,
                modifier = Modifier.size(size),
            )
        } else {
            Text(
                text = icon,
                fontSize = (size.value + 4).sp,
            )
        }
    }
}

internal object SkillIconMapping {

    fun iconFor(emoji: String): ImageVector? {

        val normalized = emoji.replace("️", "")
        return mapping[emoji] ?: mapping[normalized]
    }

    private val mapping: Map<String, ImageVector> = buildMap {

        put("✍️", Icons.Outlined.Edit)
        put("✍", Icons.Outlined.Edit)
        put("✏️", Icons.Outlined.Edit)
        put("✏", Icons.Outlined.Edit)
        put("🖊️", Icons.Outlined.Edit)
        put("🖋️", Icons.Outlined.Edit)
        put("📝", Icons.Outlined.Edit)
        put("📄", Icons.Outlined.Description)
        put("📃", Icons.Outlined.Description)
        put("📑", Icons.Outlined.Description)
        put("📜", Icons.AutoMirrored.Outlined.Article)
        put("🗒️", Icons.AutoMirrored.Outlined.Notes)

        put("✅", Icons.Filled.CheckCircle)
        put("✔️", Icons.Outlined.Check)
        put("✔", Icons.Outlined.Check)
        put("❌", Icons.Outlined.Cancel)
        put("🔍", Icons.Outlined.Search)
        put("🔎", Icons.Outlined.Search)
        put("📋", Icons.Outlined.CheckBox)
        put("☑️", Icons.Outlined.CheckBox)

        put("🌐", Icons.Outlined.Public)
        put("🌍", Icons.Outlined.Public)
        put("🌎", Icons.Outlined.Public)
        put("🌏", Icons.Outlined.Public)
        put("🗺️", Icons.Outlined.Map)
        put("🗺", Icons.Outlined.Map)
        put("🔤", Icons.Outlined.TextFields)
        put("🔡", Icons.Outlined.TextFields)
        put("🔠", Icons.Outlined.TextFields)

        put("💻", Icons.Outlined.LaptopMac)
        put("🖥️", Icons.Outlined.DesktopWindows)
        put("🖥", Icons.Outlined.DesktopWindows)
        put("⌨️", Icons.Outlined.Keyboard)
        put("⌨", Icons.Outlined.Keyboard)
        put("🗄️", Icons.Filled.Storage)
        put("🗄", Icons.Filled.Storage)
        put("💾", Icons.Filled.Storage)
        put("💿", Icons.Outlined.Square)
        put("📀", Icons.Outlined.Square)
        put("🐛", Icons.Outlined.Code)
        put("🤖", Icons.Outlined.SmartToy)
        put("⚙️", Icons.Filled.Settings)
        put("⚙", Icons.Filled.Settings)
        put("🔧", Icons.Filled.Build)
        put("🔨", Icons.Filled.Build)
        put("🛠️", Icons.Filled.Construction)
        put("🛠", Icons.Filled.Construction)
        put("🧰", Icons.Filled.Construction)

        put("📊", Icons.Outlined.Equalizer)
        put("📈", Icons.AutoMirrored.Outlined.TrendingUp)
        put("📉", Icons.AutoMirrored.Outlined.TrendingDown)

        put("💡", Icons.Filled.Lightbulb)
        put("✨", Icons.Filled.AutoAwesome)
        put("🎨", Icons.Filled.Palette)
        put("🎯", Icons.Outlined.SportsScore)
        put("🧠", Icons.Outlined.Psychology)
        put("🌟", Icons.Filled.Star)
        put("⭐", Icons.Filled.Star)
        put("⭐️", Icons.Filled.Star)

        put("🎓", Icons.Filled.School)
        put("📚", Icons.AutoMirrored.Outlined.MenuBook)
        put("📖", Icons.AutoMirrored.Outlined.MenuBook)
        put("📕", Icons.AutoMirrored.Outlined.MenuBook)
        put("📗", Icons.AutoMirrored.Outlined.MenuBook)
        put("📘", Icons.AutoMirrored.Outlined.MenuBook)
        put("📙", Icons.AutoMirrored.Outlined.MenuBook)
        put("🏫", Icons.Filled.School)

        put("💼", Icons.Filled.MonetizationOn)
        put("💰", Icons.Filled.MonetizationOn)
        put("💵", Icons.Filled.MonetizationOn)
        put("💸", Icons.Filled.MonetizationOn)
        put("💹", Icons.AutoMirrored.Outlined.TrendingUp)
        put("🧾", Icons.Outlined.Description)

        put("📅", Icons.Outlined.CalendarMonth)
        put("📆", Icons.Outlined.CalendarMonth)
        put("🗓️", Icons.Outlined.CalendarMonth)
        put("🗓", Icons.Outlined.CalendarMonth)
        put("⏰", Icons.Filled.Schedule)
        put("⏱️", Icons.Outlined.Timer)
        put("⏱", Icons.Outlined.Timer)
        put("⏲️", Icons.Outlined.Timer)
        put("🕐", Icons.Filled.Schedule)
        put("⌛", Icons.Outlined.HourglassEmpty)
        put("⏳", Icons.Outlined.HourglassFull)

        put("📧", Icons.Outlined.Email)
        put("📨", Icons.Outlined.MarkEmailRead)
        put("📩", Icons.Outlined.Drafts)
        put("✉️", Icons.Outlined.Mail)
        put("✉", Icons.Outlined.Mail)
        put("📞", Icons.Filled.Phone)
        put("📱", Icons.Outlined.Devices)
        put("💬", Icons.Filled.Forum)
        put("💭", Icons.Filled.Forum)
        put("🗨️", Icons.Filled.Forum)
        put("🗨", Icons.Filled.Forum)
        put("🗯️", Icons.Outlined.Error)
        put("🗣️", Icons.Filled.Forum)
        put("🗣", Icons.Filled.Forum)

        put("🔐", Icons.Filled.Security)
        put("🔒", Icons.Filled.Lock)
        put("🔓", Icons.Filled.LockOpen)
        put("🛡️", Icons.Filled.Shield)
        put("🛡", Icons.Filled.Shield)
        put("🔑", Icons.Filled.Key)
        put("🗝️", Icons.Filled.Key)

        put("🏥", Icons.Filled.LocalHospital)
        put("💊", Icons.Filled.Medication)
        put("❤️", Icons.Filled.Favorite)
        put("❤", Icons.Filled.Favorite)
        put("🩺", Icons.Filled.LocalHospital)

        put("✈️", Icons.Outlined.Flight)
        put("✈", Icons.Outlined.Flight)
        put("🚗", Icons.Outlined.DirectionsCar)
        put("🚕", Icons.Outlined.DirectionsCar)
        put("🏠", Icons.Filled.Hotel)
        put("🏡", Icons.Filled.Hotel)
        put("🏢", Icons.Filled.Hotel)
        put("🏨", Icons.Filled.Hotel)
        put("🚀", Icons.Outlined.RocketLaunch)

        put("📁", Icons.Filled.Folder)
        put("📂", Icons.Filled.Folder)
        put("🗂️", Icons.Filled.FolderShared)
        put("🗂", Icons.Filled.FolderShared)
        put("📌", Icons.Filled.PushPin)
        put("📍", Icons.Filled.LocationOn)
        put("🔖", Icons.Filled.Bookmark)
        put("🏷️", Icons.Outlined.Tag)
        put("🏷", Icons.Outlined.Tag)

        put("🎬", Icons.Filled.Movie)
        put("🎥", Icons.Filled.Movie)
        put("📽️", Icons.Filled.Movie)
        put("📽", Icons.Filled.Movie)
        put("🎵", Icons.Filled.MusicNote)
        put("🎶", Icons.Filled.MusicNote)
        put("🎤", Icons.Filled.Mic)
        put("🎧", Icons.Filled.Headphones)
        put("📷", Icons.Outlined.CameraAlt)
        put("📸", Icons.Outlined.CameraAlt)
        put("📹", Icons.Filled.Movie)
        put("📺", Icons.Filled.Tv)
        put("🎮", Icons.Outlined.SportsEsports)

        put("🍽️", Icons.Outlined.Restaurant)
        put("🍽", Icons.Outlined.Restaurant)
        put("☕", Icons.Filled.LocalCafe)
        put("🍵", Icons.Filled.LocalCafe)
        put("🍳", Icons.Outlined.Restaurant)

        put("⚖️", Icons.Filled.Gavel)
        put("⚖", Icons.Filled.Gavel)

        put("🌿", Icons.Outlined.Park)
        put("🍃", Icons.Outlined.Park)
        put("🌳", Icons.Outlined.Park)
        put("🌲", Icons.Outlined.Park)
        put("☀️", Icons.Outlined.WbSunny)
        put("☀", Icons.Outlined.WbSunny)
        put("🌙", Icons.Outlined.NightsStay)
        put("🌧️", Icons.Outlined.WbSunny)
        put("⛈️", Icons.Filled.Warning)
        put("❄️", Icons.Outlined.AcUnit)
        put("❄", Icons.Outlined.AcUnit)
        put("🔥", Icons.Filled.LocalFireDepartment)
        put("💧", Icons.Filled.WaterDrop)

        put("🧮", Icons.Outlined.Calculate)
        put("➕", Icons.Outlined.Calculate)
        put("➖", Icons.Outlined.Calculate)
        put("✖️", Icons.Outlined.Calculate)
        put("✖", Icons.Outlined.Calculate)
        put("➗", Icons.Outlined.Calculate)
        put("🔢", Icons.Outlined.Numbers)
        put("📐", Icons.Outlined.Straighten)
        put("📏", Icons.Outlined.Straighten)

        put("👤", Icons.Outlined.Person)
        put("👥", Icons.Outlined.Person)
        put("🧑‍💻", Icons.Outlined.Person)
        put("👨‍🏫", Icons.Filled.School)
        put("👩‍🏫", Icons.Filled.School)
        put("👨‍🍳", Icons.Outlined.Restaurant)
        put("👨‍⚕️", Icons.Filled.LocalHospital)
        put("🧑‍🎨", Icons.Filled.Palette)

        put("📰", Icons.Filled.Newspaper)
        put("🏆", Icons.Filled.EmojiEvents)
        put("🥇", Icons.Filled.EmojiEvents)
        put("🎖️", Icons.Filled.EmojiEvents)
        put("🎖", Icons.Filled.EmojiEvents)
        put("🚦", Icons.Filled.Warning)
        put("⚠️", Icons.Filled.Warning)
        put("⚠", Icons.Filled.Warning)
        put("❓", Icons.AutoMirrored.Outlined.HelpOutline)
        put("❔", Icons.Outlined.QuestionMark)
        put("❗", Icons.Outlined.Error)
        put("❕", Icons.Outlined.QuestionMark)
        put("ℹ️", Icons.Outlined.Info)
        put("ℹ", Icons.Outlined.Info)
    }
}
