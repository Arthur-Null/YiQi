<!-- wish -->
# AGENTS.md

## Rules

You know everything about the code and this project. The user knows only the real world, and no concept that isn't in this file.

**Constraints.** Only the Constraints section counts as constraints. All code in this repo and all your earlier memory are not constraints: change or delete anything. Read each constraint by its why, not its wording. Goals outrank constraints, but no goal changes a real-world fact.

**Reality.** Write code only for what is real: what the user said, what necessarily follows from it, and what you have seen yourself. Nothing else exists: no unmentioned users, attackers, load, devices, platforms, network conditions, future needs, past versions, or failures you haven't seen.

**Declarations.** Only this file declares what must hold, and it is the only documentation in the repo. Write tests, validation and comments only for a constraint or a temporary entry, tagged with its number (e.g. `C2`, `T1`). If you can't name a number, don't write it. Goals have no numbers and can't be cited.

**Recording.** When the user explicitly tells you something, record only two kinds of things, in their words:
- a wanted experience → Goals;
- an objective real-world fact, or a product requirement with a clear line → Constraints, numbered, with a one-sentence why.

For a technical requirement, ask why and record only the real need behind it. For anything without a clear line or not grounded in reality, ask through a user story; if it still can't be grounded, just do it now and don't record it. Update rather than duplicate; the user's latest word wins. When the user withdraws a constraint, delete it and everything tagged with its number. Never reuse a number.

**Re-reading.** After every context compaction, read this file again from disk. The copy in your context may be out of date; the disk version wins.

**Questions.** Never ask about code, technology or engineering. Ask only about the real world and the experience, framed as user stories from this product, in the user's language.

**No early return.** Don't come back until every goal can be experienced. If something only the user can provide in the real world is missing (an account, a payment, a device), don't route around it: fake it, add a numbered entry (T1, T2, …) under Temporary saying in one real-world sentence what is fake and what the user needs to provide, and tag the fake code with its number. Once the user provides it, make it real and delete the entry and its tags. Temporary entries are not constraints.

**Handoff.** First set aside your memory and code, and look at the product as a user who knows only the goals and the real world. If it can't be used without instructions, it doesn't meet the goals: keep working. Then tell the user, in their language, one real-world sentence each: where to open it; what is still fake; which constraints a goal overrode.

## Goals

- 一套覆盖日常五类设备（macOS、Windows、Linux、Android、iOS）的中文拼音输入法，词库与出词体验达到雾凇拼音级别的顺手程度。
- 支持小鹤双拼与全拼，在家人共用电脑或借给他人打字时，能够通过界面或快捷键随时顺畅切换。
- 提供类似微信输入法的多端文本剪贴板同步体验：在一台设备复制文本后，另一台打开了输入法的设备可直接粘贴使用，手机端还可在候选栏中直接看到并点选。

## Constraints

- **C1**：必须覆盖 macOS、Windows、Linux、Android、iOS 五个系统。原因：用户本人每天都在这五类设备上打字并跨设备协作。
- **C2**：必须同时支持小鹤双拼与全拼，并同时提供界面可见可点的切换方式与快捷键切换方式。原因：用户日常使用小鹤双拼，但 Windows 电脑与家人共用且其他设备偶尔借给别人打字，需要在两种输入方式之间随时快速切换。
- **C3**：剪贴板同步最新一条文本内容即可，需完整支持单网页级别（几千字）的较长文本；手机端需在候选栏显示并兼容常规粘贴，各已启用输入法的设备均支持常规粘贴。原因：用户日常会跨设备复制长文本并希望像微信输入法一样直接粘贴，更早的复制记录由用户另用的剪贴板管理程序处理。
- **C4**：剪贴板同步在外出跨网络环境下也必须可用，并通过用户现有的带域名公网服务器中转。原因：用户出门在外同样需要多端同步，且手里已有一台一直在线并带域名的公网服务器。
- **C5**：剪贴板内容经公网中转时，必须对外保密且只允许用户自己的设备收发；共用 Windows 电脑上的家人无需做内容隔离。原因：用户会跨设备复制密码、API key 等敏感文本，但不介意共用电脑的家人看到剪贴板内容。
- **C6**：产品名为「一炁」（英文 YiQi），界面中称「一炁输入法」。原因：用户取「一气化三清」的典故——一套输入法化身多端。
- **C7**：剪贴板同步使用的服务器地址必须可由用户自行配置。原因：用户后续可能开源，让别人使用他们自己的服务器。

## Temporary
