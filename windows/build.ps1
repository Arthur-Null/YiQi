# C1, C6: 构建 Windows 版「一炁输入法」安装包（dist\YiQi-Windows-Setup.exe）。
$ErrorActionPreference = "Stop"

$Root = (Resolve-Path "$PSScriptRoot\..").Path
$Version = (Get-Content "$Root\VERSION" -Raw).Trim()
$BuildDir = "$Root\build\windows"
$Stage = "$BuildDir\stage"
$WeaselVersion = "0.17.4"
$WeaselTag = "0.17.4"
$WeaselZip = "$Root\build\dl\weasel-$WeaselVersion.0-installer.exe"

New-Item -ItemType Directory -Force -Path "$BuildDir", "$Stage\data", "$Root\build\dl", "$Root\dist" | Out-Null

# 1. 准备雾凇拼音与一炁补丁（含 weasel.yaml）
$RimeIceCommit = "927e1cf1d3eeb9bf4be85e3f684dba4dd485b6f6"
$RimeSrc = "$Root\build\src\rime-ice"
if (-not (Test-Path "$RimeSrc\.git")) {
    git clone -q https://github.com/iDvel/rime-ice.git $RimeSrc
}
git -C $RimeSrc fetch -q --depth 1 origin $RimeIceCommit
git -C $RimeSrc checkout -q $RimeIceCommit

$RimeOut = "$BuildDir\rime-data"
if (Test-Path $RimeOut) { Remove-Item -Recurse -Force $RimeOut }
New-Item -ItemType Directory -Force -Path $RimeOut | Out-Null
$Exclude = @(".git", ".github", "others", "README.md", "AGENTS.md", "build",
    "double_pinyin.schema.yaml", "double_pinyin_abc.schema.yaml",
    "double_pinyin_jiajia.schema.yaml", "double_pinyin_mspy.schema.yaml",
    "double_pinyin_sogou.schema.yaml", "double_pinyin_ziguang.schema.yaml",
    "t9.schema.yaml")
Get-ChildItem -Force $RimeSrc | Where-Object { $Exclude -notcontains $_.Name } | ForEach-Object {
    Copy-Item -Recurse -Force $_.FullName "$RimeOut\$($_.Name)"
}
Copy-Item -Recurse -Force "$Root\rime\*" $RimeOut
foreach ($pair in @("default:default", "rime_ice.schema:rime_ice", "double_pinyin_flypy.schema:double_pinyin_flypy", "weasel:weasel")) {
    $parts = $pair.Split(":")
    $target = "$RimeOut\$($parts[0]).yaml"
    if (-not (Test-Path $target)) { Set-Content -Path $target -Value "" -Encoding UTF8 }
    Add-Content -Path $target -Value "`n__patch:`n  - qi_patch:/$($parts[1])`n  - $($parts[1]).custom:/patch?`n" -Encoding UTF8
}

# 2. 提取官方小狼毫 0.16.3 运行时（含 librime.dll 与 librime-lua 插件）
if (-not (Test-Path $WeaselZip)) {
    Invoke-WebRequest -Uri "https://github.com/rime/weasel/releases/download/$WeaselTag/weasel-$WeaselVersion.0-installer.exe" -OutFile $WeaselZip
}
$ExtractDir = "$BuildDir\weasel-bin"
if (Test-Path $ExtractDir) { Remove-Item -Recurse -Force $ExtractDir }
New-Item -ItemType Directory -Force -Path $ExtractDir | Out-Null
7z x -aou "-o$ExtractDir" $WeaselZip | Out-Null

foreach ($f in @("WeaselServer.exe", "WeaselDeployer.exe", "WeaselSetup.exe", "rime.dll", "WinSparkle.dll", "weasel.dll", "weaselx64.dll", "weasel.ime", "weaselx64.ime")) {
    if (Test-Path "$ExtractDir\$f") { Copy-Item -Force "$ExtractDir\$f" "$Stage\$f" }
}
$SharedSrc = Get-ChildItem -Path $ExtractDir -Directory -Filter "data" -Recurse | Select-Object -First 1
if ($SharedSrc) {
    foreach ($f in @("key_bindings.yaml", "punctuation.yaml", "symbols.yaml")) {
        if (Test-Path "$($SharedSrc.FullName)\$f") { Copy-Item -Force "$($SharedSrc.FullName)\$f" "$Stage\data\$f" }
    }
    if (Test-Path "$($SharedSrc.FullName)\opencc") {
        Copy-Item -Recurse -Force "$($SharedSrc.FullName)\opencc" "$Stage\data\opencc"
    }
}
Copy-Item -Recurse -Force "$RimeOut\*" "$Stage\data\"

# 3. 编译 Go 版一炁设置与剪贴板同步伴侣（YiQi.exe）
Push-Location "$Root\windows\app"
$env:GOOS = "windows"
$env:GOARCH = "amd64"
$env:CGO_ENABLED = "0"
go build -ldflags "-H=windowsgui -s -w -X main.version=$Version" -o "$Stage\YiQi.exe" .
Pop-Location

# 4. 使用 NSIS 打包安装程序
makensis /V2 "$Root\windows\installer\yiqi.nsi"
Write-Host "Built: $Root\dist\YiQi-Windows-Setup.exe"
