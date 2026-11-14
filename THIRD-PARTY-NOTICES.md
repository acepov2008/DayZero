# Third-party notices

## WinUtil (Chris Titus Tech)

DayZero's clean-up levels (Clear / Minimal / Standard / Advanced) follow the tweak presets and
the default AppX selection of WinUtil, https://github.com/ChrisTitusTech/winutil. The lists of
settings were adapted into `kit/config/tweaks.json` and `kit/config/debloat.json`; DayZero's
code is its own. `debloat.json` > `winutil` documents every preset item and where DayZero differs.

```
MIT License

Copyright (c) 2022 CT Tech Group LLC

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## tiny11builder (ntdevlabs)

The optional "Make it tiny11" choice runs `tiny11maker.ps1` from
https://github.com/ntdevlabs/tiny11builder. That project publishes no licence, so none of its
files are included in DayZero. The builder downloads the script and its `autounattend.xml`
from GitHub at commit `38f7ab6b1f177098c026a19b73ec84bca9c4b874` on the user's PC, checks their
SHA-256, and runs the script unchanged. tiny11 and tiny11builder are the work of ntdevlabs.
