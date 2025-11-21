# 🥔 “薛定谔的山芋”项目开发
---

### **项目模块与架构**

1.  **核心合约 (`src/Potato.sol`)**:
    *   这将是项目的唯一核心合约。它将是一个 `ERC721` 标准的 NFT。这个 NFT 本身就是那个“山芋”。
    *   我们将在该合约中集成所有游戏逻辑，而不是将它们分散到多个合约中。这样可以简化交互并降低 Gas 成本。
    *   **继承**：合约将继承自 OpenZeppelin 的 `ERC721`（用于实现 NFT 功能）和 `Ownable`（用于管理合约的特殊权限，如设置游戏参数）。

2.  **合约内部模块划分 (逻辑层面)**:
    *   **数据结构 (State & Structs)**: `GameState` 枚举, `GameInfo` 结构体，以及所有事件 (`Event`) 的定义。这是合约状态的基础。
    *   **核心游戏逻辑 (Core Logic)**: `tossPotato` 和 `resolveToss` 函数。这是游戏玩法的心脏。
    *   **经济模型 (Tokenomics)**: `calculatePendingYield` 视图函数和在 `resolveToss` 中集成的奖励/惩罚逻辑。
    *   **辅助/工具函数 (Utils)**: 如 `_calculateRisk` 这样的内部纯函数，用于计算爆炸概率。

3.  **文件结构 (物理层面)**:
    *   `src/Potato.sol`: 核心合约文件。
    *   `test/Potato.t.sol`: Foundry 测试文件，用于测试所有功能。
    *   `script/Deploy.s.sol`: Foundry 部署脚本。
    *   `script/interactions/`: 存放后期交互脚本的目录（如 `play.ts`, `keeper-bot.ts`）。

---

# 🥔 项目开发待办清单 (Project To-Do List)

**项目核心：** 基于区块哈希延时结算的概率博弈游戏。
**技术栈：** Solidity (Hardhat/Foundry), TypeScript (用于脚本交互)。

---

### 阶段一：架构与数据结构设计 (Architecture Design)
**目标：** 确立状态机、存储结构和事件接口，这是“无前端”玩法的核心。

*   [ ] **1.1 定义核心结构体与状态机**
    *   设计 `GameState` (记录山芋位置、时间)。
    *   设计 `TossRequest` (记录投掷动作的快照)。
    *   设计 `Enum State` (`Idle`, `InFlight`)。
*   [ ] **1.2 定义事件 (Events)**
    *   因为没有前端，Events 必须清晰，方便我们在 Etherscan 上看 Log 玩游戏。
    *   需要：`PotatoTossed`, `PotatoExploded`, `PotatoLanded`, `YieldClaimed`.

### 阶段二：核心逻辑开发 (Core Development)
**目标：** 实现“投掷-揭晓”的异步逻辑和概率算法。

*   [ ] **2.1 实现 `tossPotato` (动作层)**
    *   编写权限检查：只有当前持有人能调。
    *   编写状态锁定：从 `Idle` 变更为 `InFlight`，记录当前区块高度。
*   [ ] **2.2 实现概率计算器 (数学层)**
    *   编写 `_calculateRisk(uint256 holdTime)` 纯函数。
    *   输入持有秒数，返回 5, 30, 60, 或 100 (爆炸百分比)。
*   [ ] **2.3 实现 `resolveToss` (结算层)**
    *   **难点：** 获取 `blockhash(tossBlock + 1)`。
    *   **逻辑：** 生成伪随机数 -> 对比风险值 -> 执行（转移 NFT 或 炸毁）。
    *   **防死锁：** 处理 256 个区块后哈希无法获取的情况（判定为自动爆炸）。

### 阶段三：经济模型与激励 (Tokenomics) - 详细版
**目标：** 构建一个包含稳定收益和博弈大奖的双重激励系统。

*   [ ] **3.1 创建 ERC20 奖励代币 (`PotatoYield.sol`)**
    *   编写一个标准的 ERC20 合约，作为持有山芋的奖励。
    *   它需要包含一个 `mint(address to, uint256 amount)` 函数。
    *   这个 `mint` 函数必须设置为只有主 `Potato.sol` 合约才能调用（使用 `Ownable` 模式，将 `owner` 设置为主合约地址）。

*   [ ] **3.2 升级核心数据结构**
    *   为了实现“幸存者”奖励，我们需要知道是谁把山芋传给了当前爆炸的玩家。
    *   修改 `GameInfo` 结构体，增加一个 `address public lastSuccessfulTosser` 字段，用于记录上一位成功传出山芋的玩家。

*   [ ] **3.3 实现持有收益 (Yield) 逻辑**
    *   在 `Potato.sol` 中增加一个可配置的 `yieldRate` 变量（例如，每秒产生的 `PotatoYield` 代币数量）。
    *   编写一个公开的 `calculatePendingYield()` 视图函数，用于实时查询当前持有者累积的待领取收益。
    *   在 `resolveToss` 的“安全着陆”逻辑分支中，为**上一位持有者**（`from` 地址）调用 `PotatoYield` 合约的 `mint` 函数，发放奖励。

*   [ ] **3.4 实现爆炸奖池 (Jackpot) 逻辑**
    *   将 `tossPotato` 函数修改为 `payable`。
    *   增加一个可配置的 `entryFee` 变量（每次传递所需支付的 ETH 费用）。
    *   在 `tossPotato` 中，要求 `msg.value` 必须等于 `entryFee`，并将收到的 ETH 存入合约中作为奖池。
    *   在 `resolveToss` 的“爆炸”逻辑分支中：
        *   确定奖池的赢家为 `gameInfo.lastSuccessfulTosser`。
        *   将合约中的全部 ETH 余额（`address(this).balance`）转给这位赢家。

*   [ ] **3.5 编写对应的测试用例**
    *   测试 `calculatePendingYield` 计算是否准确。
    *   测试安全着陆后，上一位持有者是否收到了正确数量的 `PotatoYield` 代币。
    *   测试 `tossPotato` 时支付了错误的 `entryFee` 会被 revert。
    *   测试山芋爆炸后，“幸存者”是否收到了正确的奖池 ETH。

### 阶段四：测试与攻防 (Testing & Security)
**目标：** 模拟各种极端情况，确保博弈公平。

*   [ ] **4.1 基础流程测试**
    *   A 传给 B，B 传给 C，正常流转。
*   [ ] **4.2 概率分布测试 (Fuzzing)**
    *   模拟 1000 次 `resolveToss`，验证 5%, 30%, 60% 的爆炸率是否符合预期。
*   [ ] **4.3 边界条件测试**
    *   测试在同一个区块内连续调用（应该被 ReentrancyGuard 或 状态机拦截）。
    *   测试超过 256 个区块没人开奖的情况。

### 阶段五：极客交互脚本 (Scripts - The "No Frontend" UI)
**目标：** 你是工程师，你不需要网页，你需要 CLI 工具。

*   [ ] **5.1 编写 `play.ts` 脚本**
    *   功能：查询当前谁拿着山芋？现在的爆炸概率是多少？
    *   功能：一键调用 `tossPotato`。
*   [ ] **5.2 编写 `keeper-bot.ts` 脚本**
    *   功能：轮询链上状态，发现有 `InFlight` 状态且区块已确认时，自动调用 `resolveToss` 赚取执行费。