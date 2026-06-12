import Foundation

/// Curated SF Symbol names offered in the category icon picker, grouped by
/// theme. The picker reads `all` for its (searchable) flat grid; `groups`
/// exists for any future sectioned layout.
///
/// Every name here is a stock SF Symbol that ships on macOS 14. An invalid
/// name renders as a blank cell, so the list is intentionally limited to
/// common, long-stable symbols rather than the full SF catalog. Selecting
/// from this fixed set is also what keeps `Category.iconValue` (an
/// unvalidated String) constrained to real symbols, with no free-text path.
enum CategorySymbols {
    /// Logical sections, in the order they should appear. The flat `all`
    /// list is derived from these, de-duplicated, preserving first occurrence.
    static let groups: [(title: String, symbols: [String])] = [
        (
            "General",
            [
                "pin.fill", "star.fill", "heart.fill", "bolt.fill", "flame.fill",
                "tag.fill", "bookmark.fill", "flag.fill", "bell.fill", "lightbulb.fill",
                "sparkles", "wand.and.stars", "crown.fill", "trophy.fill", "medal.fill",
                "checkmark.seal.fill", "exclamationmark.triangle.fill", "questionmark.circle.fill",
                "info.circle.fill", "hand.thumbsup.fill", "hand.raised.fill",
            ]
        ),
        (
            "Communication",
            [
                "envelope", "envelope.fill", "envelope.open.fill", "paperplane.fill", "message.fill",
                "bubble.left.fill", "bubble.right.fill", "phone.fill", "video.fill",
                "at", "link", "antenna.radiowaves.left.and.right", "globe",
                "person.fill", "person.2.fill", "person.3.fill", "person.crop.circle.fill",
                "megaphone.fill", "quote.bubble.fill",
            ]
        ),
        (
            "Files & Folders",
            [
                "folder", "folder.fill", "folder.badge.plus", "tray.full.fill", "tray.2.fill",
                "archivebox.fill", "doc.fill", "doc.text.fill", "doc.on.doc.fill",
                "doc.richtext.fill", "text.alignleft", "list.bullet", "list.bullet.rectangle.fill",
                "paperclip", "clipboard.fill", "square.and.arrow.up.fill",
                "square.and.arrow.down.fill", "externaldrive.fill", "internaldrive.fill",
                "shippingbox.fill", "trash.fill",
            ]
        ),
        (
            "Finance",
            [
                "creditcard.fill", "banknote.fill", "dollarsign.circle.fill",
                "eurosign.circle.fill", "sterlingsign.circle.fill", "yensign.circle.fill",
                "bitcoinsign.circle.fill", "cart.fill", "bag.fill", "gift.fill",
                "giftcard.fill", "chart.line.uptrend.xyaxis", "chart.bar.fill",
                "chart.pie.fill", "percent", "scalemass.fill", "building.columns.fill",
                "wallet.pass.fill",
            ]
        ),
        (
            "Media",
            [
                "photo", "photo.fill", "photo.on.rectangle.fill", "camera.fill", "video.fill",
                "film.fill", "play.fill", "pause.fill", "music.note", "music.note.list",
                "headphones", "mic.fill", "speaker.wave.2.fill", "radio.fill", "tv.fill",
                "guitars.fill", "paintpalette.fill", "paintbrush.fill", "pencil.tip",
                "scribble", "wand.and.rays", "paintpalette",
            ]
        ),
        (
            "Work",
            [
                "briefcase.fill", "case.fill", "building.2.fill", "calendar",
                "clock.fill", "timer", "alarm.fill", "stopwatch.fill", "deskclock.fill",
                "graduationcap.fill", "book.fill", "books.vertical.fill", "newspaper.fill",
                "pencil", "highlighter", "ruler.fill", "hammer.fill", "wrench.and.screwdriver.fill",
                "gearshape.fill", "gearshape.2.fill", "printer.fill", "scanner.fill",
            ]
        ),
        (
            "Tech & Code",
            [
                "terminal.fill", "curlybraces", "chevron.left.forwardslash.chevron.right",
                "keyboard.fill", "desktopcomputer", "laptopcomputer", "display",
                "cpu.fill", "memorychip.fill", "server.rack", "externaldrive.connected.to.line.below.fill",
                "network", "wifi", "bolt.horizontal.fill", "key.fill", "lock.fill",
                "lock.open.fill", "shield.fill", "shield.lefthalf.filled", "ladybug.fill",
            ]
        ),
        (
            "Travel & Places",
            [
                "house.fill", "building.fill", "airplane", "car.fill", "bus.fill",
                "tram.fill", "bicycle", "fuelpump.fill", "map.fill", "mappin.circle.fill",
                "location.fill", "signpost.right.fill", "ferry.fill", "sailboat.fill",
                "globe.americas.fill", "globe.europe.africa.fill", "globe.asia.australia.fill",
                "suitcase.fill", "tent.fill", "mountain.2.fill",
            ]
        ),
        (
            "Nature & Weather",
            [
                "leaf.fill", "tree.fill", "drop.fill", "flame.fill", "snowflake",
                "sun.max.fill", "moon.fill", "moon.stars.fill", "cloud.fill",
                "cloud.rain.fill", "cloud.bolt.fill", "wind", "tornado", "hurricane",
                "pawprint.fill", "fish.fill", "ant.fill", "tortoise.fill", "hare.fill",
                "carrot.fill",
            ]
        ),
        (
            "Health & Food",
            [
                "heart.text.square.fill", "cross.case.fill", "pills.fill", "bandage.fill",
                "stethoscope", "bed.double.fill", "dumbbell.fill", "figure.walk",
                "figure.run", "cup.and.saucer.fill", "mug.fill", "wineglass.fill",
                "fork.knife", "birthday.cake.fill", "takeoutbag.and.cup.and.straw.fill",
            ]
        ),
        (
            "Symbols & Shapes",
            [
                "circle.fill", "square.fill", "triangle.fill", "diamond.fill",
                "hexagon.fill", "seal.fill", "shield.lefthalf.filled", "checkmark.circle.fill",
                "xmark.circle.fill", "plus.circle.fill", "minus.circle.fill",
                "arrow.up.circle.fill", "arrow.down.circle.fill", "arrow.right.circle.fill",
                "arrow.triangle.2.circlepath", "ellipsis.circle.fill", "asterisk",
                "number", "infinity", "function", "command", "option",
            ]
        ),
        (
            "Activities & Objects",
            [
                "gamecontroller.fill", "dice.fill", "puzzlepiece.fill", "die.face.5.fill",
                "balloon.fill", "party.popper.fill", "theatermasks.fill", "ticket.fill",
                "popcorn.fill", "key.horizontal.fill", "umbrella.fill", "eyeglasses",
                "scissors", "paperclip.badge.ellipsis", "magnifyingglass", "binoculars.fill",
                "lifepreserver.fill", "battery.100", "powerplug.fill", "lightbulb.led.fill",
            ]
        ),
    ]

    /// Flat, de-duplicated list backing the searchable grid. First occurrence
    /// wins so the General section stays at the top of the picker.
    static let all: [String] = {
        var seen = Set<String>()
        var result: [String] = []
        for group in groups {
            for symbol in group.symbols where !seen.contains(symbol) {
                seen.insert(symbol)
                result.append(symbol)
            }
        }
        return result
    }()
}
