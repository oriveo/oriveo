# Third-party notices

Oriveo Community Edition is licensed under [AGPL-3.0-or-later](LICENSE). The repository also
carries a small number of assets that belong to other people, under their own terms, and the
clients identify model providers by their names and logos. This file records both.

Library dependencies are not vendored: each client's package manager fetches them at build time
under the license each library declares (`ios/Oriveo/Oriveo.xcodeproj`,
`android/gradle/libs.versions.toml`, `web/package-lock.json`).

## Fonts

### Plus Jakarta Sans

Bundled in the iOS client (`ios/Oriveo/Oriveo/PlusJakartaSans-Bold.ttf`) and the Android client
(`android/app/src/main/res/font/plus_jakarta_sans_wght.ttf`), version 2.071.

Copyright 2020 The Plus Jakarta Sans Project Authors
(<https://github.com/tokotype/PlusJakartaSans>).

This Font Software is licensed under the SIL Open Font License, Version 1.1. The license text is
reproduced at the end of this file and is available with a FAQ at <https://scripts.sil.org/OFL>.

### Inter and JetBrains Mono

The web client loads both through `next/font/google`, which downloads them at build time and
serves them from the built application; neither file is checked into this repository. Both are
licensed under the SIL Open Font License, Version 1.1.

- Inter — Copyright 2016 The Inter Project Authors (<https://github.com/rsms/inter>)
- JetBrains Mono — Copyright 2020 The JetBrains Mono Project Authors
  (<https://github.com/JetBrains/JetBrainsMono>)

## Mathematics rendering

- **KaTeX** (web) — MIT License, Copyright (c) 2013-2020 Khan Academy and other contributors.
  Its stylesheet and the fonts it ships are served from the built application.
- **JLaTeXMath for Android** (`ru.noties:jlatexmath-android` and its Cyrillic and Greek font
  packages) — GPL-2.0-or-later with the linking exception granted by the JLaTeXMath authors,
  which permits linking it into this AGPL-3.0-or-later application.

## Provider names and logos

The clients ship the names and logos of the model providers they can be pointed at, in
`ios/Oriveo/Oriveo/Assets.xcassets/Provider*.imageset`, `android/app/src/main/res/drawable*/`
(`ic_provider_*`, `ic_vendor_*`) and `web/apps/app/public/plogos/` and
`web/apps/app/public/providers/vendors/`.

Those names and logos are trademarks of their respective owners. They appear here only to identify
the third-party services a user may connect to with their own account, and their presence does not
imply endorsement, sponsorship or affiliation. They are not covered by this repository's license;
if you redistribute a modified client, check each owner's brand guidelines yourself.

## Oriveo name and logo

"Oriveo" and the Oriveo logo (`docs/assets/logo.png` and the app icons) identify this project and
the products built from it. The source code is yours under the AGPL; the name and logo are not
licensed for use on a modified distribution in a way that suggests it is the original.

---

## SIL Open Font License, Version 1.1

Copyright (c) 2020 The Plus Jakarta Sans Project Authors
(<https://github.com/tokotype/PlusJakartaSans>)

This Font Software is licensed under the SIL Open Font License, Version 1.1.
This license is copied below, and is also available with a FAQ at:
<https://scripts.sil.org/OFL>

SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007

PREAMBLE

The goals of the Open Font License (OFL) are to stimulate worldwide development of collaborative
font projects, to support the font creation efforts of academic and linguistic communities, and to
provide a free and open framework in which fonts may be shared and improved in partnership with
others.

The OFL allows the licensed fonts to be used, studied, modified and redistributed freely as long as
they are not sold by themselves. The fonts, including any derivative works, can be bundled,
embedded, redistributed and/or sold with any software provided that any reserved names are not used
by derivative works. The fonts and derivatives, however, cannot be released under any other type of
license. The requirement for fonts to remain under this license does not apply to any document
created using the fonts or their derivatives.

DEFINITIONS

"Font Software" refers to the set of files released by the Copyright Holder(s) under this license
and clearly marked as such. This may include source files, build scripts and documentation.

"Reserved Font Name" refers to any names specified as such after the copyright statement(s).

"Original Version" refers to the collection of Font Software components as distributed by the
Copyright Holder(s).

"Modified Version" refers to any derivative made by adding to, deleting, or substituting -- in part
or in whole -- any of the components of the Original Version, by changing formats or by porting the
Font Software to a new environment.

"Author" refers to any designer, engineer, programmer, technical writer or other person who
contributed to the Font Software.

PERMISSION & CONDITIONS

Permission is hereby granted, free of charge, to any person obtaining a copy of the Font Software,
to use, study, copy, merge, embed, modify, redistribute, and sell modified and unmodified copies of
the Font Software, subject to the following conditions:

1) Neither the Font Software nor any of its individual components, in Original or Modified
Versions, may be sold by itself.

2) Original or Modified Versions of the Font Software may be bundled, redistributed and/or sold
with any software, provided that each copy contains the above copyright notice and this license.
These can be included either as stand-alone text files, human-readable headers or in the
appropriate machine-readable metadata fields within text or binary files as long as those fields
can be easily viewed by the user.

3) No Modified Version of the Font Software may use the Reserved Font Name(s) unless explicit
written permission is granted by the corresponding Copyright Holder. This restriction only applies
to the primary font name as presented to the users.

4) The name(s) of the Copyright Holder(s) or the Author(s) of the Font Software shall not be used
to promote, endorse or advertise any Modified Version, except to acknowledge the contribution(s) of
the Copyright Holder(s) and the Author(s) or with their explicit written permission.

5) The Font Software, modified or unmodified, in part or in whole, must be distributed entirely
under this license, and must not be distributed under any other license. The requirement for fonts
to remain under this license does not apply to any document created using the Font Software.

TERMINATION

This license becomes null and void if any of the above conditions are not met.

DISCLAIMER

THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
BUT NOT LIMITED TO ANY WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT OF COPYRIGHT, PATENT, TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL THE COPYRIGHT
HOLDER BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, INCLUDING ANY GENERAL, SPECIAL,
INDIRECT, INCIDENTAL, OR CONSEQUENTIAL DAMAGES, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM OTHER
DEALINGS IN THE FONT SOFTWARE.
