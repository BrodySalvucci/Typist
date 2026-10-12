import Foundation

public struct Emoji: Equatable {
    public var character: String
    public var shortcodes: [String]
    /// Accepts a skin tone modifier.
    public var toneable: Bool
}

/// Shortcode search: type `:joy` and get 😂.
public enum EmojiCatalog {
    /// The shortcode being typed at the end of `text` (without the colon), if any.
    /// The colon must start a word so times ("10:30") and URLs don't trigger.
    public static func query(in text: String) -> String? {
        var query = ""
        for character in text.reversed() {
            if character == ":" {
                let beforeColon = text.dropLast(query.count + 1).last
                guard beforeColon == nil || beforeColon!.isWhitespace, query.count >= 2 else { return nil }
                return String(query.reversed())
            }
            guard character.isASCII, character.isLetter || character.isNumber || character == "_" || character == "+" || character == "-",
                  query.count < 30 else { return nil }
            query.append(character)
        }
        return nil
    }

    /// Best matches first: exact, then prefix, then substring; catalog order within each group.
    public static func search(_ query: String, limit: Int = 5) -> [Emoji] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return [] }
        var exact: [Emoji] = [], prefix: [Emoji] = [], contains: [Emoji] = []
        for emoji in all {
            if emoji.shortcodes.contains(needle) {
                exact.append(emoji)
            } else if emoji.shortcodes.contains(where: { $0.hasPrefix(needle) }) {
                prefix.append(emoji)
            } else if needle.count >= 3, emoji.shortcodes.contains(where: { $0.contains(needle) }) {
                contains.append(emoji)
            }
        }
        return Array((exact + prefix + contains).prefix(limit))
    }

    /// - Parameter tone: 0 for the default, 1...5 for light to dark.
    public static func render(_ emoji: Emoji, skinTone tone: Int) -> String {
        guard emoji.toneable, (1...5).contains(tone), let modifier = Unicode.Scalar(0x1F3FA + tone),
              let first = emoji.character.unicodeScalars.first else { return emoji.character }
        var scalars = String.UnicodeScalarView()
        scalars.append(first)
        scalars.append(modifier)
        // Drop a variation selector that directly followed the base, keep the rest (e.g. ZWJ sequences).
        scalars.append(contentsOf: emoji.character.unicodeScalars.dropFirst().drop { $0.value == 0xFE0F })
        return String(scalars)
    }

    public static let all: [Emoji] = table.split(separator: "\n").compactMap { line in
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let toneable = parts[0].hasSuffix("*")
        let character = toneable ? String(parts[0].dropLast()) : String(parts[0])
        return Emoji(character: character, shortcodes: parts.dropFirst().map(String.init), toneable: toneable)
    }

    /// `emoji[*] shortcode [aliases…]`; `*` marks emoji that take a skin tone. Most used first.
    private static let table = """
    😂 joy laughing_crying
    ❤️ heart red_heart love
    🤣 rofl rolling_on_the_floor_laughing
    👍* thumbsup +1 thumbs_up yes
    😭 sob crying_loudly
    🙏* pray thanks please folded_hands
    😘 kissing_heart kiss
    🥰 smiling_face_with_hearts in_love
    😍 heart_eyes
    😊 blush smile_blush
    🎉 tada party celebrate
    😁 grin beaming
    💕 two_hearts
    🥺 pleading puppy_eyes
    😅 sweat_smile phew
    🔥 fire lit
    ☺️ relaxed
    🤦* facepalm
    ♥️ hearts
    🤷* shrug
    🙄 roll_eyes eyeroll
    😆 laughing satisfied
    🤗 hugs hugging
    😉 wink
    🎂 birthday cake
    🤔 thinking think hmm
    👏* clap applause
    🙂 slightly_smiling_face slight_smile
    😳 flushed
    🥳 partying_face party_face
    😎 sunglasses cool
    👌* ok_hand okay perfect
    💜 purple_heart
    😔 pensive
    💪* muscle strong flex
    ✨ sparkles
    💖 sparkling_heart
    👀 eyes look
    😋 yum
    😏 smirk
    😢 cry sad
    👉* point_right
    💗 heartpulse
    😩 weary
    💯 100 hundred
    🌹 rose
    💞 revolving_hearts
    🎈 balloon
    💙 blue_heart
    😃 smiley
    😡 rage angry_red
    💐 bouquet flowers
    😜 stuck_out_tongue_winking_eye
    🙈 see_no_evil
    🤞* crossed_fingers fingers_crossed
    😄 smile
    🤤 drooling_face drool
    🙌* raised_hands hooray
    🤪 zany_face crazy
    ❣️ heavy_heart_exclamation
    😀 grinning
    💋 kiss_mark lips
    💀 skull dead
    👇* point_down
    💔 broken_heart
    😌 relieved
    💓 heartbeat
    🤩 star_struck starstruck
    🙃 upside_down upside_down_face
    😬 grimacing
    😱 scream
    😴 sleeping zzz_face
    🤭 hand_over_mouth giggle
    😐 neutral_face
    🌞 sun_with_face
    😒 unamused
    😇 innocent angel
    🌸 cherry_blossom
    😈 smiling_imp devil
    🎶 notes music
    ✌️* v peace victory
    🎊 confetti_ball
    🥵 hot_face
    😞 disappointed
    💚 green_heart
    ☀️ sunny sun
    🖤 black_heart
    💰 moneybag money
    😚 kissing_closed_eyes
    👑 crown
    🎁 gift present
    💥 boom collision
    🙋* raising_hand
    ☹️ frowning_face
    😑 expressionless
    🥴 woozy_face
    👈* point_left
    💩 poop hankey
    ✅ white_check_mark check done
    👋* wave hello bye
    🤮 vomiting_face
    😤 triumph huff
    🤢 nauseated_face
    🌟 star2 glowing_star
    ❗ exclamation
    😥 disappointed_relieved
    🌈 rainbow
    💛 yellow_heart
    😝 stuck_out_tongue_closed_eyes
    😫 tired_face
    😲 astonished
    🖕* middle_finger
    ‼️ bangbang
    🔴 red_circle
    🌻 sunflower
    🤯 exploding_head mind_blown
    💃* dancer
    👊* punch fist_bump facepunch
    🤬 cursing_face
    🏃* runner running
    😕 confused
    ⚡ zap lightning
    ☕ coffee
    🍀 four_leaf_clover luck
    💦 sweat_drops
    ⭐ star
    🦋 butterfly
    🤨 raised_eyebrow
    🌺 hibiscus
    😹 joy_cat
    🤘* metal rock_on
    🌷 tulip
    💝 gift_heart
    💤 zzz
    🤝 handshake deal
    🐰 rabbit bunny
    😓 sweat
    💘 cupid
    🍻 beers cheers
    😟 worried
    😣 persevere
    🧐 monocle_face
    😠 angry
    🤠 cowboy
    😻 heart_eyes_cat
    🌙 crescent_moon moon
    😛 stuck_out_tongue
    🤙* call_me shaka
    🙊 speak_no_evil
    🧡 orange_heart
    🤡 clown
    🤫 shushing_face shh
    🌼 blossom
    🥂 clinking_glasses toast champagne_glasses
    😷 mask
    🤓 nerd
    🥶 cold_face
    😶 no_mouth
    😖 confounded
    🎵 musical_note
    🚶* walking
    😙 kissing_smiling_eyes
    🍆 eggplant
    🤑 money_mouth
    😗 kissing
    🐶 dog puppy
    🍓 strawberry
    👅 tongue
    👄 mouth
    🌿 herb
    ⚠️ warning
    📣 mega megaphone
    🍑 peach
    🤧 sneezing_face
    🍁 maple_leaf
    👻 ghost
    🍒 cherries
    😮 open_mouth wow
    🚀 rocket ship launch
    🍕 pizza
    🍺 beer
    🍷 wine wine_glass
    🍔 hamburger burger
    🌮 taco
    🍰 cake_slice
    🍎 apple
    🐱 cat kitty
    🦄 unicorn
    🐛 bug
    🌍 earth_africa earth globe
    🌊 ocean wave_water
    ❄️ snowflake snow
    ☔ umbrella rain
    ⏰ alarm_clock
    ⏳ hourglass
    📅 calendar date
    📌 pushpin pin
    📎 paperclip
    📝 memo note pencil
    📧 email e-mail
    📞 phone telephone
    💻 computer laptop
    📱 iphone mobile
    🔒 lock
    🔑 key
    🔍 mag search
    💡 bulb idea
    🔧 wrench fix
    🛠️ tools hammer_and_wrench
    ⚙️ gear settings
    📈 chart_with_upwards_trend chart_up
    📉 chart_with_downwards_trend chart_down
    📊 bar_chart
    💵 dollar
    💳 credit_card
    🏆 trophy
    🥇 first_place gold_medal
    🎯 dart target bullseye
    🎮 video_game gaming
    🎧 headphones
    📷 camera
    🎬 clapper movie
    📚 books
    ✏️ pencil2
    ✈️ airplane plane
    🚗 car
    🏠 house home
    🏢 office
    ❌ x cross_mark no
    ❓ question
    ➡️ arrow_right
    ⬅️ arrow_left
    ⬆️ arrow_up
    ⬇️ arrow_down
    🔗 link
    ♻️ recycle
    🆗 ok
    🆕 new
    🔔 bell
    🚨 rotating_light alert siren
    🚧 construction wip
    🐢 turtle slow
    🐍 snake
    🐳 whale
    🦊 fox
    🐻 bear
    🐼 panda
    🐸 frog
    🐵 monkey_face monkey
    🦁 lion
    🐷 pig
    🐔 chicken
    🐧 penguin
    🤖 robot
    👽 alien
    👶* baby
    🧠 brain
    👁️ eye
    🦷 tooth
    🫶* heart_hands
    🫡 saluting_face salute
    🫠 melting_face
    🥹 face_holding_back_tears
    🫣 peeking_eye
    🤌* pinched_fingers
    ✍️* writing_hand
    🤏* pinching_hand
    👎* thumbsdown -1 thumbs_down
    ✊* fist
    🖐️* raised_hand_with_fingers_splayed hand
    ☝️* point_up
    """
}
