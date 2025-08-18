# FlowX CLMM (Concentrated Liquidity Market Maker)

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Move](https://img.shields.io/badge/language-Move-orange.svg)](https://github.com/move-language/move)

A concentrated liquidity market maker (CLMM) protocol built on the Sui blockchain, inspired by Uniswap v3. FlowX CLMM allows liquidity providers to concentrate their capital within custom price ranges, increasing capital efficiency and providing traders with lower slippage.

## 📋 Table of Contents

- [📖 Overview](#-overview)
- [🔧 Core Functions](#-core-functions)
- [📋 API Reference](#-api-reference)
- [💡 Developer Guide](#-developer-guide)
- [🔮 Price Oracle System](#-price-oracle-system)
- [🧮 Mathematical Libraries](#-mathematical-libraries)
- [📦 Deployment](#-deployment)

## 📖 Overview

FlowX CLMM implements a concentrated liquidity model with the following core features:

### 🎯 Key Features

| Feature                    | Description                                      |
| -------------------------- | ------------------------------------------------ |
| **Concentrated Liquidity** | Capital efficiency through custom price ranges   |
| **Multiple Fee Tiers**     | Flexible fee structures (0.01%, 0.05%, 0.3%, 1%) |
| **Position Management**    | NFT-based position tracking and management       |
| **Protocol Rewards**       | Built-in reward distribution system              |
| **Oracle Integration**     | Price feeds and historical data tracking         |
| **Modular Architecture**   | Clean separation with versioning support         |

### 💰 Benefits

- **For Liquidity Providers**: Higher capital efficiency and customizable risk exposure
- **For Traders**: Lower slippage and better price discovery
- **For Developers**: Modular design for easy integration and extension

### 🏗️ Architecture

#### Core Modules

#### 🏦 Pool Manager (`pool_manager.move`)

Central registry for all pools in the protocol.

- Pool creation and registration
- Fee tier management
- Administrative functions
- Protocol fee collection

#### 🌊 Pool (`pool.move`)

Individual pool implementation containing the core AMM logic.

- Liquidity management
- Swap execution
- Tick state management
- Oracle data collection
- Reward distribution

#### 📊 Position Manager (`position_manager.move`)

Manages the lifecycle of liquidity positions.

- Position creation and closure
- Liquidity adjustments
- Fee collection
- Reward claiming

#### 🔄 Swap Router (`swap_router.move`)

Handles swap execution with various input/output specifications.

- Exact input/output swaps
- Price limit enforcement
- Slippage protection

## 🔧 Core Functions

### 🏊 Pool Management

<details>
<summary><strong>create_pool_v2</strong> - Create a new liquidity pool</summary>

Creates a new liquidity pool for token pair X/Y with specified fee rate.

```move
public fun create_pool_v2<X, Y>(
    self: &mut PoolRegistry,
    fee_rate: u64,
    metadata_x: &CoinMetadata<X>,
    metadata_y: &CoinMetadata<Y>,
    versioned: &Versioned,
    ctx: &mut TxContext
)
```

**Parameters:**

- `fee_rate`: Fee rate in basis points (e.g., 3000 = 0.3%)
- `metadata_x/y`: Coin metadata for validation
- `versioned`: Package version validation

**Example:**

```move
// Create a new USDC/SUI pool with 0.3% fee
// Note: Fee rate must be enabled first via enable_fee_rate_for_testing in tests
pool_manager::create_pool_v2<USDC, SUI>(
    &mut pool_registry,
    3000, // 0.3% fee tier
    &usdc_metadata,
    &sui_metadata,
    &versioned,
    ctx
);
```

</details>

<details>
<summary><strong>create_and_initialize_pool_v2</strong> - Create and initialize pool with price</summary>

Creates and initializes a new pool in a single transaction with an initial price.

```move
public fun create_and_initialize_pool_v2<X, Y>(
    self: &mut PoolRegistry,
    fee_rate: u64,
    sqrt_price: u128,
    metadata_x: &CoinMetadata<X>,
    metadata_y: &CoinMetadata<Y>,
    versioned: &Versioned,
    clock: &Clock,
    ctx: &mut TxContext
)
```

**Parameters:**

- `sqrt_price`: Initial square root price as Q64.64 fixed-point number
- Additional parameters same as `create_pool_v2`

**Example:**

```move
// Create and initialize USDC/SUI pool with initial price of 1 USDC = 2 SUI
// sqrt_price = sqrt(0.5) * 2^64 for price of 0.5 USDC per SUI
let initial_sqrt_price = 13043817825332782212; // sqrt(0.5) in Q64.64 format

pool_manager::create_and_initialize_pool_v2<USDC, SUI>(
    &mut pool_registry,
    3000, // 0.3% fee tier
    initial_sqrt_price,
    &usdc_metadata,
    &sui_metadata,
    &versioned,
    &clock,
    ctx
);
```

</details>

### 📍 Position Management

<details>
<summary><strong>open_position</strong> - Open a new liquidity position</summary>

Opens a new liquidity position within specified tick range.

```move
public fun open_position<X, Y>(
    self: &mut PositionRegistry,
    pool_registry: &PoolRegistry,
    fee_rate: u64,
    tick_lower_index: I32,
    tick_upper_index: I32,
    versioned: &Versioned,
    ctx: &mut TxContext
): Position
```

**Example:**

```move
let position = position_manager::open_position<USDC, SUI>(
    &mut position_registry,
    &pool_registry,
    3000, // 0.3% fee
    tick_lower,
    tick_upper,
    &versioned,
    ctx
);
```

**Complete Liquidity Provider Workflow Example:**

```move
// 1. Calculate tick range for price range $1.80 - $2.20 per SUI
// Assuming USDC has 6 decimals and SUI has 9 decimals
let lower_price = 1_800000; // $1.80 in USDC units (6 decimals)
let upper_price = 2_200000; // $2.20 in USDC units (6 decimals)

// Convert prices to sqrt prices (Q64.64 format)
let lower_sqrt_price = price_to_sqrt_price(lower_price, 6, 9);
let upper_sqrt_price = price_to_sqrt_price(upper_price, 6, 9);

// Convert sqrt prices to ticks
let tick_lower = tick_math::get_tick_at_sqrt_price(lower_sqrt_price);
let tick_upper = tick_math::get_tick_at_sqrt_price(upper_sqrt_price);

// 2. Open position in the calculated range
let position = position_manager::open_position<USDC, SUI>(
    &mut position_registry,
    &pool_registry,
    3000, // 0.3% fee tier
    tick_lower,
    tick_upper,
    &versioned,
    ctx
);
```

**Parameters:**

- `self`: Mutable reference to the position registry
- `pool_registry`: Reference to the pool registry for validation
- `fee_rate`: Pool fee rate in basis points (e.g., 3000 = 0.3%)
- `tick_lower_index`: Lower bound of the price range as tick index
- `tick_upper_index`: Upper bound of the price range as tick index
- `versioned`: Reference for package version validation
- `ctx`: Transaction context

**Returns:**

- `Position`: New position NFT for tracking and management

</details>

<details>
<summary><strong>increase_liquidity</strong> - Add liquidity to position</summary>

Adds liquidity to an existing position with slippage protection.

```move
public fun increase_liquidity<X, Y>(
    self: &mut PoolRegistry,
    position: &mut Position,
    x_in: Coin<X>,
    y_in: Coin<Y>,
    amount_x_min: u64,
    amount_y_min: u64,
    deadline: u64,
    versioned: &Versioned,
    clock: &Clock,
    ctx: &mut TxContext
)
```

**Parameters:**

- `self`: Mutable reference to the pool registry
- `position`: Mutable reference to the position to add liquidity to
- `x_in`: Coin of token X to add as liquidity
- `y_in`: Coin of token Y to add as liquidity
- `amount_x_min`: Minimum amount of X tokens to add (slippage protection)
- `amount_y_min`: Minimum amount of Y tokens to add (slippage protection)
- `deadline`: Transaction deadline timestamp to prevent stale transactions
- `versioned`: Reference for package version validation
- `clock`: Clock object for timing validation
- `ctx`: Transaction context

**Returns:**

- Excess tokens are automatically refunded to the caller

**Example:**

```move
// Add 1000 USDC and 2000 SUI to position with slippage protection
let usdc_coins = coin::mint_for_testing<USDC>(1000_000000, ctx); // 1000 USDC (6 decimals)
let sui_coins = coin::mint_for_testing<SUI>(2000_000000000, ctx); // 2000 SUI (9 decimals)
let deadline = clock::timestamp_ms(&clock) + 300_000; // 5 minutes from now

position_manager::increase_liquidity<USDC, SUI>(
    &mut pool_registry,
    &mut position,
    usdc_coins,
    sui_coins,
    950_000000,  // Min 950 USDC (5% slippage tolerance)
    1900_000000000, // Min 1900 SUI (5% slippage tolerance)
    deadline,
    &versioned,
    &clock,
    ctx
);
```

</details>

<details>
<summary><strong>decrease_liquidity</strong> - Remove liquidity from position</summary>

Removes liquidity from a position and returns tokens.

```move
public fun decrease_liquidity<X, Y>(
    self: &mut PoolRegistry,
    position: &mut Position,
    liquidity: u128,
    amount_x_min: u64,
    amount_y_min: u64,
    deadline: u64,
    versioned: &Versioned,
    clock: &Clock,
    ctx: &mut TxContext
)
```

**Parameters:**

- `self`: Mutable reference to the pool registry
- `position`: Mutable reference to the position to remove liquidity from
- `liquidity`: Amount of liquidity to remove (in liquidity units)
- `amount_x_min`: Minimum amount of X tokens to receive (slippage protection)
- `amount_y_min`: Minimum amount of Y tokens to receive (slippage protection)
- `deadline`: Transaction deadline timestamp to prevent stale transactions
- `versioned`: Reference for package version validation
- `clock`: Clock object for timing validation
- `ctx`: Transaction context

**Returns:**

- Token balances proportional to the liquidity removed

**Example:**

```move
// Remove 50% of position liquidity
let current_liquidity = position::liquidity(&position);
let liquidity_to_remove = current_liquidity / 2;
let deadline = clock::timestamp_ms(&clock) + 300_000; // 5 minutes from now

position_manager::decrease_liquidity<USDC, SUI>(
    &mut pool_registry,
    &mut position,
    liquidity_to_remove,
    100_000000,   // Min 100 USDC expected
    200_000000000, // Min 200 SUI expected
    deadline,
    &versioned,
    &clock,
    ctx
);
```

</details>

### 💰 Fee & Reward Collection

<details>
<summary><strong>collect</strong> - Collect accumulated fees</summary>

Collects accumulated trading fees from a position.

```move
public fun collect<X, Y>(
    self: &mut PoolRegistry,
    position: &mut Position,
    amount_x_requested: u64,
    amount_y_requested: u64,
    versioned: &Versioned,
    clock: &Clock,
    ctx: &mut TxContext
): (Coin<X>, Coin<Y>)
```

**Parameters:**

- `self`: Mutable reference to the pool registry
- `position`: Mutable reference to the position to collect fees from
- `amount_x_requested`: Maximum amount of X token fees to collect
- `amount_y_requested`: Maximum amount of Y token fees to collect
- `versioned`: Reference for package version validation
- `clock`: Clock object for timing validation
- `ctx`: Transaction context

**Returns:**

- `(Coin<X>, Coin<Y>)`: Tuple of collected fee coins for both tokens

**Example:**

```move
// Collect all accumulated trading fees from position
let (usdc_fees, sui_fees) = position_manager::collect<USDC, SUI>(
    &mut pool_registry,
    &mut position,
    18446744073709551615, // Max u64 to collect all USDC fees
    18446744073709551615, // Max u64 to collect all SUI fees
    &versioned,
    &clock,
    ctx
);

// Use collected fees
let usdc_fee_amount = coin::value(&usdc_fees);
let sui_fee_amount = coin::value(&sui_fees);
// Transfer to treasury or reinvest
```

</details>

<details>
<summary><strong>collect_pool_reward</strong> - Collect reward tokens</summary>

Collects accumulated reward tokens for a position.

```move
public fun collect_pool_reward<X, Y, RewardCoinType>(
    self: &mut PoolRegistry,
    position: &mut Position,
    amount_requested: u64,
    versioned: &Versioned,
    clock: &Clock,
    ctx: &mut TxContext
): Coin<RewardCoinType>
```

**Parameters:**

- `self`: Mutable reference to the pool registry
- `position`: Mutable reference to the position to collect rewards from
- `amount_requested`: Maximum amount of reward tokens to collect
- `versioned`: Reference for package version validation
- `clock`: Clock object for timing validation
- `ctx`: Transaction context

**Type Parameters:**

- `X`: First token type of the pool
- `Y`: Second token type of the pool
- `RewardCoinType`: Type of the reward token to collect

**Returns:**

- `Coin<RewardCoinType>`: Collected reward tokens of the specified type

**Example:**

```move
// Collect FLOW reward tokens from USDC/SUI position
let flow_rewards = position_manager::collect_pool_reward<USDC, SUI, FLOW>(
    &mut pool_registry,
    &mut position,
    18446744073709551615, // Max u64 to collect all available FLOW rewards
    &versioned,
    &clock,
    ctx
);

let reward_amount = coin::value(&flow_rewards);
// Transfer rewards to user wallet
transfer::public_transfer(flow_rewards, tx_context::sender(ctx));
```

</details>

### 🔄 Swap Functions

<details>
<summary><strong>Exact Input Swaps</strong> - Swap exact amount in for maximum out</summary>

```move
// Swap exact X for maximum Y
public fun swap_exact_x_to_y<X, Y>(
    pool: &mut Pool<X, Y>,
    coin_in: Coin<X>,
    sqrt_price_limit: u128,
    versioned: &Versioned,
    clock: &Clock,
    ctx: &TxContext
): Balance<Y>

// Swap exact Y for maximum X
public fun swap_exact_y_to_x<X, Y>(
    pool: &mut Pool<X, Y>,
    coin_in: Coin<Y>,
    sqrt_price_limit: u128,
    versioned: &Versioned,
    clock: &Clock,
    ctx: &TxContext
): Balance<X>
```

**Parameters:**

- `pool`: Mutable reference to the pool to execute swap in
- `coin_in`: Input tokens to swap (entire amount will be consumed)
- `sqrt_price_limit`: Price limit for slippage protection:
  - For X→Y swaps: Maximum acceptable sqrt price after swap (price decreasing)
  - For Y→X swaps: Minimum acceptable sqrt price after swap (price increasing)
- `versioned`: Reference for package version validation
- `clock`: Clock object for timing validation
- `ctx`: Transaction context

**Returns:**

- `Balance<Y>` or `Balance<X>`: Output token balance from the swap

**Use Case:** When you want to swap all of a token

**Example:**

```move
// Swap 1000 USDC for maximum SUI possible
let usdc_in = coin::mint_for_testing<USDC>(1000_000000, ctx); // 1000 USDC
let current_sqrt_price = pool::sqrt_price_current(&pool);
let min_sqrt_price = (current_sqrt_price * 95) / 100; // 5% slippage tolerance

let sui_out = swap_router::swap_exact_x_to_y<USDC, SUI>(
    &mut pool,
    usdc_in,
    min_sqrt_price,
    &versioned,
    &clock,
    ctx
);

let sui_amount_received = balance::value(&sui_out);
// Convert balance to coin if needed
let sui_coin = coin::from_balance(sui_out, ctx);
```

</details>

<details>
<summary><strong>Exact Output Swaps</strong> - Swap minimum in for exact amount out</summary>

```move
// Swap minimum X for exact Y
public fun swap_x_to_exact_y<X, Y>(
    pool: &mut Pool<X, Y>,
    coin_in: Coin<X>,
    amount_out: u64,
    sqrt_price_limit: u128,
    versioned: &Versioned,
    clock: &Clock,
    ctx: &TxContext
): Balance<Y>

// Swap minimum Y for exact X
public fun swap_y_to_exact_x<X, Y>(
    pool: &mut Pool<X, Y>,
    coin_in: Coin<Y>,
    amount_out: u64,
    sqrt_price_limit: u128,
    versioned: &Versioned,
    clock: &Clock,
    ctx: &TxContext
): Balance<X>
```

**Parameters:**

- `pool`: Mutable reference to the pool to execute swap in
- `coin_in`: Input tokens to swap (excess will be refunded)
- `amount_out`: Exact amount of output tokens to receive
- `sqrt_price_limit`: Price limit for slippage protection:
  - For X→Y swaps: Maximum acceptable sqrt price after swap
  - For Y→X swaps: Minimum acceptable sqrt price after swap
- `versioned`: Reference for package version validation
- `clock`: Clock object for timing validation
- `ctx`: Transaction context

**Returns:**

- `Balance<Y>` or `Balance<X>`: Exact amount of output tokens requested

**Use Case:** When you need a precise output amount

**Example:**

```move
// Swap minimum USDC needed to get exactly 500 SUI
let usdc_in = coin::mint_for_testing<USDC>(2000_000000, ctx); // 2000 USDC (excess will be refunded)
let desired_sui_out = 500_000000000; // Exactly 500 SUI (9 decimals)
let current_sqrt_price = pool::sqrt_price_current(&pool);
let max_sqrt_price = (current_sqrt_price * 105) / 100; // 5% slippage tolerance

let sui_out = swap_router::swap_x_to_exact_y<USDC, SUI>(
    &mut pool,
    usdc_in, // Will be split internally, excess refunded
    desired_sui_out,
    max_sqrt_price,
    &versioned,
    &clock,
    ctx
);

// Verify exact amount received
assert!(balance::value(&sui_out) == desired_sui_out, 0);
let sui_coin = coin::from_balance(sui_out, ctx);
```

</details>

## 📋 API Reference

This section provides detailed parameter descriptions for all core functions.

### Pool Management Functions

| Function                              | Purpose                                                            | Access Level |
| ------------------------------------- | ------------------------------------------------------------------ | ------------ |
| `create_pool_v2<X, Y>`                | Creates a new liquidity pool for token pair X/Y                    | Public       |
| `create_and_initialize_pool_v2<X, Y>` | Creates and initializes pool with initial price in one transaction | Public       |

#### create_pool_v2<X, Y>

- **Purpose**: Creates a new liquidity pool for token pair X/Y
- **Fee Rate**: Must be previously enabled (e.g., 3000 for 0.3%)
- **Access**: Public - can be called by any user

#### create_and_initialize_pool_v2<X, Y>

- **Purpose**: Creates and initializes pool with initial price in one transaction
- **Initial Price**: Specified as Q64.64 fixed-point sqrt price
- **Access**: Public - can be called by any user

### Position Management Functions

| Function                                 | Purpose                                                  | Returns             |
| ---------------------------------------- | -------------------------------------------------------- | ------------------- |
| `open_position<X, Y>`                    | Opens new liquidity position within specified tick range | Position NFT        |
| `close_position`                         | Closes empty position and destroys NFT                   | None                |
| `increase_liquidity<X, Y>`               | Adds liquidity to existing position                      | Auto-refunds excess |
| `decrease_liquidity<X, Y>`               | Removes liquidity from position                          | Token balances      |
| `collect<X, Y>`                          | Collects accumulated trading fees from position          | Fee coins           |
| `collect_pool_reward<X, Y, RewardToken>` | Collects reward tokens earned by position                | Reward coins        |

#### open_position<X, Y>

- **Purpose**: Opens new liquidity position within specified tick range
- **Tick Range**: Must respect pool's tick spacing requirements
- **Returns**: Position NFT for tracking and management

#### increase_liquidity<X, Y>

- **Purpose**: Adds liquidity to existing position
- **Slippage Protection**: `amount_x_min` and `amount_y_min` parameters
- **Auto-refund**: Excess tokens automatically returned
- **Deadline**: Prevents execution of stale transactions

#### decrease_liquidity<X, Y>

- **Purpose**: Removes liquidity from position
- **Returns**: Token balances proportional to liquidity removed
- **Minimum Output**: Slippage protection via `amount_x_min`/`amount_y_min`

#### collect<X, Y>

- **Purpose**: Collects accumulated trading fees from position
- **Fee Collection**: Specify maximum amounts to collect
- **Returns**: Collected fee balances for both tokens

#### collect_pool_reward<X, Y, RewardToken>

- **Purpose**: Collects reward tokens earned by position
- **Reward Type**: Specify exact reward token type
- **Returns**: Coin of specified reward token type

#### close_position

- **Purpose**: Closes empty position and destroys NFT
- **Requirements**: Position must have zero liquidity, fees, and rewards

### Swap Functions

| Function Category     | Functions                                | Use Case                                      |
| --------------------- | ---------------------------------------- | --------------------------------------------- |
| **Exact Input**       | `swap_exact_x_to_y`, `swap_exact_y_to_x` | Swap all tokens for maximum output            |
| **Exact Output**      | `swap_x_to_exact_y`, `swap_y_to_exact_x` | Use minimum input for precise output          |
| **High-Level Router** | `swap_exact_input`, `swap_exact_output`  | Simplified interface with auto pool selection |

#### Exact Input Swaps

- **swap_exact_x_to_y**: Swap all X tokens for maximum Y tokens
- **swap_exact_y_to_x**: Swap all Y tokens for maximum X tokens
- **Use Case**: When you want to sell entire token balance

#### Exact Output Swaps

- **swap_x_to_exact_y**: Use minimum X tokens to get exact Y amount
- **swap_y_to_exact_x**: Use minimum Y tokens to get exact X amount
- **Use Case**: When you need precise output amount

#### High-Level Router Functions

- **swap_exact_input**: Router function for exact input swaps with deadline validation
- **swap_exact_output**: Router function for exact output swaps with deadline validation
- **Use Case**: Simplified interface for common swap operations with automatic pool selection

### Swap Functions

#### `swap_exact_x_to_y<X, Y>(pool, coin_in, sqrt_price_limit, versioned, clock, ctx)`

Swaps an exact amount of token X for token Y.

```move
public fun swap_exact_x_to_y<X, Y>(
    pool: &mut Pool<X, Y>,
    coin_in: Coin<X>,
    sqrt_price_limit: u128,
    versioned: &Versioned,
    clock: &Clock,
    ctx: &TxContext
): Balance<Y>
```

**Parameters:**

- `pool`: Mutable reference to the pool to execute swap in
- `coin_in`: X tokens to swap (entire amount will be consumed)
- `sqrt_price_limit`: Maximum acceptable sqrt price after swap (slippage protection)
- `versioned`: Reference to versioned object for package version validation
- `clock`: Clock object for timing validation
- `ctx`: Transaction context

**Returns:**

- `Balance<Y>`: Resulting Y token balance from the swap

#### `swap_exact_y_to_x<X, Y>(pool, coin_in, sqrt_price_limit, versioned, clock, ctx)`

Swaps an exact amount of token Y for token X.

**Parameters:**

- `pool`: Mutable reference to the pool to execute swap in
- `coin_in`: Y tokens to swap (entire amount will be consumed)
- `sqrt_price_limit`: Minimum acceptable sqrt price after swap (slippage protection)
- `versioned`: Reference to versioned object for package version validation
- `clock`: Clock object for timing validation
- `ctx`: Transaction context

**Returns:**

- `Balance<X>`: Resulting X token balance from the swap

#### `swap_x_to_exact_y<X, Y>(pool, coin_in, amount_out, sqrt_price_limit, versioned, clock, ctx)`

Swaps token X for an exact amount of token Y.

**Parameters:**

- `pool`: Mutable reference to the pool to execute swap in
- `coin_in`: X tokens to swap (excess will be refunded)
- `amount_out`: Exact amount of Y tokens to receive
- `sqrt_price_limit`: Maximum acceptable sqrt price after swap
- `versioned`: Reference to versioned object for package version validation
- `clock`: Clock object for timing validation
- `ctx`: Transaction context

**Returns:**

- `Balance<Y>`: Exact amount of Y tokens requested

#### `swap_y_to_exact_x<X, Y>(pool, coin_in, amount_out, sqrt_price_limit, versioned, clock, ctx)`

Swaps token Y for an exact amount of token X.

**Parameters:**

- `pool`: Mutable reference to the pool to execute swap in
- `coin_in`: Y tokens to swap (excess will be refunded)
- `amount_out`: Exact amount of X tokens to receive
- `sqrt_price_limit`: Minimum acceptable sqrt price after swap
- `versioned`: Reference to versioned object for package version validation
- `clock`: Clock object for timing validation
- `ctx`: Transaction context

**Returns:**

- `Balance<X>`: Exact amount of X tokens requested

#### `swap_exact_input<X, Y>(pool_registry, fee, coin_in, amount_out_min, sqrt_price_limit, deadline, versioned, clock, ctx)`

High-level router function for exact input swaps with automatic pool selection and deadline validation.

```move
public fun swap_exact_input<X, Y>(
    pool_registry: &mut PoolRegistry,
    fee: u64,
    coin_in: Coin<X>,
    amount_out_min: u64,
    sqrt_price_limit: u128,
    deadline: u64,
    versioned: &Versioned,
    clock: &Clock,
    ctx: &mut TxContext
): Coin<Y>
```

**Parameters:**

- `pool_registry`: Mutable reference to the pool registry
- `fee`: Pool fee rate to select the correct pool
- `coin_in`: Input tokens to swap (entire amount will be consumed)
- `amount_out_min`: Minimum amount of output tokens expected (slippage protection)
- `sqrt_price_limit`: Price limit for slippage protection
- `deadline`: Transaction deadline timestamp to prevent stale transactions
- `versioned`: Reference for package version validation
- `clock`: Clock object for timing validation
- `ctx`: Transaction context

**Returns:**

- `Coin<Y>`: Output token coin from the swap

**Features:**

- Automatic token ordering (handles both X→Y and Y→X directions)
- Built-in deadline validation
- Minimum output amount validation
- Simplified interface for common swap operations

#### `swap_exact_output<X, Y>(pool_registry, fee, coin_in, amount_out, sqrt_price_limit, deadline, versioned, clock, ctx)`

High-level router function for exact output swaps with automatic pool selection and deadline validation.

```move
public fun swap_exact_output<X, Y>(
    pool_registry: &mut PoolRegistry,
    fee: u64,
    coin_in: Coin<X>,
    amount_out: u64,
    sqrt_price_limit: u128,
    deadline: u64,
    versioned: &Versioned,
    clock: &Clock,
    ctx: &mut TxContext
): Coin<Y>
```

**Parameters:**

- `pool_registry`: Mutable reference to the pool registry
- `fee`: Pool fee rate to select the correct pool
- `coin_in`: Input tokens to swap (excess will be refunded)
- `amount_out`: Exact amount of output tokens to receive
- `sqrt_price_limit`: Price limit for slippage protection
- `deadline`: Transaction deadline timestamp to prevent stale transactions
- `versioned`: Reference for package version validation
- `clock`: Clock object for timing validation
- `ctx`: Transaction context

**Returns:**

- `Coin<Y>`: Exact amount of output tokens requested

**Features:**

- Automatic token ordering (handles both X→Y and Y→X directions)
- Built-in deadline validation
- Automatic refund of excess input tokens
- Simplified interface for precise output amount swaps

## 💡 Developer Guide

### 🎯 Complete End-to-End Example

Here's a comprehensive example showing how to create a pool, provide liquidity, perform swaps, and collect fees:

```move
public fun complete_clmm_example<USDC, SUI>(
    pool_registry: &mut PoolRegistry,
    position_registry: &mut PositionRegistry,
    usdc_metadata: &CoinMetadata<USDC>,
    sui_metadata: &CoinMetadata<SUI>,
    versioned: &Versioned,
    clock: &Clock,
    ctx: &mut TxContext
) {
    // 1. Create and initialize pool
    let initial_sqrt_price = 13043817825332782212; // sqrt(0.5) for 1 USDC = 2 SUI
    pool_manager::create_and_initialize_pool_v2<USDC, SUI>(
        pool_registry,
        3000, // 0.3% fee
        initial_sqrt_price,
        usdc_metadata,
        sui_metadata,
        versioned,
        clock,
        ctx
    );

    // 2. Open position in price range $1.80 - $2.20 per SUI
    let lower_sqrt_price = 11832159566199029792; // sqrt(1/2.20)
    let upper_sqrt_price = 14142135623730950624; // sqrt(1/1.80)
    let tick_lower = tick_math::get_tick_at_sqrt_price(lower_sqrt_price);
    let tick_upper = tick_math::get_tick_at_sqrt_price(upper_sqrt_price);

    let position = position_manager::open_position<USDC, SUI>(
        position_registry,
        pool_registry,
        3000,
        tick_lower,
        tick_upper,
        versioned,
        ctx
    );

    // 3. Add liquidity to position
    let usdc_coins = coin::mint_for_testing<USDC>(10000_000000, ctx); // 10,000 USDC
    let sui_coins = coin::mint_for_testing<SUI>(20000_000000000, ctx); // 20,000 SUI
    let deadline = clock::timestamp_ms(clock) + 300_000; // 5 minutes

    position_manager::increase_liquidity<USDC, SUI>(
        pool_registry,
        &mut position,
        usdc_coins,
        sui_coins,
        9500_000000,    // Min 9,500 USDC (5% slippage)
        19000_000000000, // Min 19,000 SUI (5% slippage)
        deadline,
        versioned,
        clock,
        ctx
    );

    // 4. Perform a swap (someone else trades)
    let trader_usdc = coin::mint_for_testing<USDC>(1000_000000, ctx); // 1,000 USDC
    let pool = pool_manager::borrow_mut_pool<USDC, SUI>(pool_registry, 3000);
    let current_sqrt_price = pool::sqrt_price_current(pool);
    let min_sqrt_price = (current_sqrt_price * 95) / 100; // 5% slippage

    let sui_out = swap_router::swap_exact_x_to_y<USDC, SUI>(
        pool,
        trader_usdc,
        min_sqrt_price,
        versioned,
        clock,
        ctx
    );

    // 5. Collect accumulated fees after some trading activity
    let (usdc_fees, sui_fees) = position_manager::collect<USDC, SUI>(
        pool_registry,
        &mut position,
        18446744073709551615, // Collect all fees (max u64)
        18446744073709551615,
        versioned,
        clock,
        ctx
    );

    // 6. Collect any reward tokens (if available)
    let rewards = position_manager::collect_pool_reward<USDC, SUI, FLOW>(
        pool_registry,
        &mut position,
        18446744073709551615, // Collect all rewards (max u64)
        versioned,
        clock,
        ctx
    );

    // 7. Remove liquidity when done
    let position_liquidity = position::liquidity(&position);
    let remove_deadline = clock::timestamp_ms(clock) + 300_000;

    position_manager::decrease_liquidity<USDC, SUI>(
        pool_registry,
        &mut position,
        position_liquidity, // Remove all liquidity
        0, // Accept any amount (or set minimums)
        0,
        remove_deadline,
        versioned,
        clock,
        ctx
    );

    // 8. Close empty position
    position_manager::close_position(position_registry, position, versioned, ctx);

    // Transfer collected fees and rewards
    transfer::public_transfer(usdc_fees, tx_context::sender(ctx));
    transfer::public_transfer(sui_fees, tx_context::sender(ctx));
    transfer::public_transfer(rewards, tx_context::sender(ctx));
    transfer::public_transfer(coin::from_balance(sui_out, ctx), tx_context::sender(ctx));
}
```

### 🚀 Quick Integration Examples

#### Basic Liquidity Provision

```move
// 1. Open position
let position = position_manager::open_position<USDC, SUI>(
    &mut position_registry,
    &pool_registry,
    3000, // 0.3% fee
    tick_lower,
    tick_upper,
    &versioned,
    ctx
);

// 2. Add liquidity
position_manager::increase_liquidity<USDC, SUI>(
    &mut pool_registry,
    &mut position,
    usdc_coins,
    sui_coins,
    min_usdc_amount,
    min_sui_amount,
    deadline,
    &versioned,
    &clock,
    ctx
);
```

#### Basic Token Swap

```move
// Swap exact USDC for maximum SUI
let sui_out = swap_router::swap_exact_x_to_y<USDC, SUI>(
    &mut pool,
    usdc_in,
    min_sqrt_price, // Slippage protection
    &versioned,
    &clock,
    ctx
);
```

#### Router Function Examples

```move
// High-level exact input swap with automatic pool selection
let usdc_in = coin::mint_for_testing<USDC>(1000_000000, ctx); // 1000 USDC
let deadline = clock::timestamp_ms(&clock) + 300_000; // 5 minutes
let current_sqrt_price = pool::sqrt_price_current(&pool);
let min_sqrt_price = (current_sqrt_price * 95) / 100; // 5% slippage

let sui_out = swap_router::swap_exact_input<USDC, SUI>(
    &mut pool_registry,
    3000, // 0.3% fee pool
    usdc_in,
    1900_000000000, // Min 1900 SUI output (5% slippage)
    min_sqrt_price,
    deadline,
    &versioned,
    &clock,
    ctx
);

// High-level exact output swap with automatic pool selection
let usdc_in = coin::mint_for_testing<USDC>(2000_000000, ctx); // 2000 USDC (excess refunded)
let exact_sui_out = 500_000000000; // Exactly 500 SUI
let max_sqrt_price = (current_sqrt_price * 105) / 100; // 5% slippage

let sui_out = swap_router::swap_exact_output<USDC, SUI>(
    &mut pool_registry,
    3000, // 0.3% fee pool
    usdc_in, // Excess will be refunded
    exact_sui_out,
    max_sqrt_price,
    deadline,
    &versioned,
    &clock,
    ctx
);

// Verify exact amount received
assert!(coin::value(&sui_out) == exact_sui_out, 0);
```

#### Swap Best Practices

**Swap Flow:**

1. **Input Validation**: Checks pool state, price limits, and token amounts
2. **Route Calculation**: Determines optimal path through active liquidity
3. **Tick Traversal**: Executes swap across multiple price ranges if needed
4. **Fee Collection**: Deducts swap fees and protocol fees
5. **Price Update**: Updates pool price and oracle data
6. **Output Delivery**: Transfers resulting tokens to user

**Swap Types:**

**Exact Input Swaps** (`swap_exact_x_to_y`, `swap_exact_y_to_x`):

```move
// Swap all USDC for maximum SUI possible
let sui_out = swap_router::swap_exact_x_to_y<USDC, SUI>(
    &mut pool,
    usdc_in,           // Entire amount consumed
    min_sqrt_price,    // Price limit (slippage protection)
    &versioned,
    &clock,
    ctx
);
```

**Exact Output Swaps** (`swap_x_to_exact_y`, `swap_y_to_exact_x`):

```move
// Swap minimum USDC needed for exact 1 SUI
let sui_out = swap_router::swap_x_to_exact_y<USDC, SUI>(
    &mut pool,
    usdc_in,           // May have excess refunded
    1_000_000_000,     // Exactly 1 SUI (9 decimals)
    max_sqrt_price,    // Price limit
    &versioned,
    &clock,
    ctx
);
```

#### Position Management Best Practices

**Opening Positions:**

```move
// Choose tick range based on strategy
let tick_lower = tick_math::get_tick_at_sqrt_price(lower_price_sqrt);
let tick_upper = tick_math::get_tick_at_sqrt_price(upper_price_sqrt);

// Ensure ticks are valid for the pool's tick spacing
let tick_spacing = pool::tick_spacing(&pool);
let adjusted_lower = (tick_lower / tick_spacing) * tick_spacing;
let adjusted_upper = (tick_upper / tick_spacing) * tick_spacing;
```

**Liquidity Management:**

- **Narrow Ranges**: Higher fees, higher impermanent loss risk
- **Wide Ranges**: Lower fees, lower impermanent loss risk
- **Active Management**: Monitor price movements and adjust ranges

**Fee Collection Strategy:**

```move
// Collect fees regularly to compound returns
let (fee_x, fee_y) = position_manager::collect<X, Y>(
    &mut pool_registry,
    &mut position,
    18446744073709551615,  // Max u64 to collect all
    18446744073709551615,  // Max u64 to collect all
    &versioned,
    &clock,
    ctx
);

// Reinvest fees by adding liquidity
position_manager::increase_liquidity<X, Y>(
    &mut pool_registry,
    &mut position,
    coin::from_balance(fee_x, ctx),
    coin::from_balance(fee_y, ctx),
    0, // No minimum since we're reinvesting fees
    0,
    deadline,
    &versioned,
    &clock,
    ctx
);
```

#### Defensive Programming Practices

```move
// Always use deadlines for time-sensitive operations
let deadline = clock::timestamp_ms(clock) + 300_000; // 5 minutes

// Set reasonable slippage tolerance (e.g., 0.5%)
let amount_min = (expected_amount * 995) / 1000;

// Check pool state before operations
assert!(pool::is_initialized(&pool), E_POOL_NOT_INITIALIZED);

// Set appropriate price limits for swaps
let current_sqrt_price = pool::sqrt_price_current(&pool);

// For X to Y swaps (price decreasing), set a lower limit
let min_sqrt_price_limit = (current_sqrt_price * 95) / 100; // 5% slippage
// Ensure it's above the absolute minimum
let safe_min_limit = math::max(min_sqrt_price_limit, tick_math::min_sqrt_price() + 1);

// For Y to X swaps (price increasing), set an upper limit
let max_sqrt_price_limit = (current_sqrt_price * 105) / 100; // 5% slippage
// Ensure it's below the absolute maximum
let safe_max_limit = math::min(max_sqrt_price_limit, tick_math::max_sqrt_price() - 1);

// Check price limits before swap to avoid errors
if (x_for_y) {
    assert!(sqrt_price_limit < current_sqrt_price, E_PRICE_LIMIT_ALREADY_EXCEEDED);
    assert!(sqrt_price_limit > tick_math::min_sqrt_price(), E_PRICE_LIMIT_OUT_OF_BOUNDS);
} else {
    assert!(sqrt_price_limit > current_sqrt_price, E_PRICE_LIMIT_ALREADY_EXCEEDED);
    assert!(sqrt_price_limit < tick_math::max_sqrt_price(), E_PRICE_LIMIT_OUT_OF_BOUNDS);
};
```

### Precision & Safety Features

- **Q64.64 Fixed-Point Arithmetic**: For precise price calculations
- **Overflow-Safe Operations**: Implements overflow-safe arithmetic operations
- **Rounding Controls**: Provides rounding controls for fee calculations

### Integration Patterns

#### Direct Pool Swap Integration

Best practices for integrating with the core `pool::swap` function for custom swap implementations:

```move
// Complete swap integration pattern
public fun custom_swap_exact_input<X, Y>(
    pool: &mut Pool<X, Y>,
    input_coin: Coin<X>,
    min_output_amount: u64,
    max_slippage_bps: u64, // basis points (e.g., 50 = 0.5%)
    versioned: &Versioned,
    clock: &Clock,
    ctx: &mut TxContext
): Coin<Y> {
    let input_amount = coin::value(&input_coin);
    let current_sqrt_price = pool::sqrt_price_current(pool);

    // Calculate price limit based on slippage tolerance
    let price_limit = if (true) { // x_for_y = true
        let slippage_factor = 10000 - max_slippage_bps; // e.g., 9950 for 0.5%
        (current_sqrt_price * (slippage_factor as u128)) / 10000
    } else {
        let slippage_factor = 10000 + max_slippage_bps; // e.g., 10050 for 0.5%
        (current_sqrt_price * (slippage_factor as u128)) / 10000
    };

    // Execute swap
    let (balance_x_out, balance_y_out, receipt) = pool::swap<X, Y>(
        pool,
        true,           // x_for_y
        true,           // exact_in
        input_amount,   // amount_specified
        price_limit,
        versioned,
        clock,
        ctx
    );

    // Pay for the swap
    pool::pay<X, Y>(
        pool,
        receipt,
        coin::into_balance(input_coin), // payment_x
        balance::zero<Y>(),             // payment_y
        versioned,
        ctx
    );

    // Validate minimum output
    let output_amount = balance::value(&balance_y_out);
    assert!(output_amount >= min_output_amount, E_INSUFFICIENT_OUTPUT_AMOUNT);

    // Return output (balance_x_out should be zero for x_for_y swaps)
    balance::destroy_zero(balance_x_out);
    coin::from_balance(balance_y_out, ctx)
}

// Precise swap with receipt-based payment amounts
public fun precise_swap_exact_input<X, Y>(
    pool: &mut Pool<X, Y>,
    input_coin: Coin<X>,
    min_output_amount: u64,
    sqrt_price_limit: u128,
    versioned: &Versioned,
    clock: &Clock,
    ctx: &mut TxContext
): (Coin<X>, Coin<Y>) { // Returns refunded input and output in (x, y) order
    let input_amount = coin::value(&input_coin);

    // Execute swap
    let (balance_x_out, balance_y_out, receipt) = pool::swap<X, Y>(
        pool,
        true,           // x_for_y
        true,           // exact_in
        input_amount,   // amount_specified
        sqrt_price_limit,
        versioned,
        clock,
        ctx
    );

    // Extract exact payment amounts from receipt
    let amount_x_needed = swap_receipt::amount_x_needed(&receipt);
    let amount_y_needed = swap_receipt::amount_y_needed(&receipt);

    // For exact_in swaps, amount_x_needed should equal input_amount
    // For x_for_y swaps, amount_y_needed should be zero
    assert!(amount_y_needed == 0, E_UNEXPECTED_Y_PAYMENT_REQUIRED); // Should be zero for x_for_y

    // Split exact amount needed for payment
    let payment_coin = coin::split(&mut input_coin, amount_x_needed, ctx);
    let payment_x = coin::into_balance(payment_coin);

    // Complete the payment
    pool::pay<X, Y>(
        pool,
        receipt,
        payment_x,
        balance::zero<Y>(),
        versioned,
        ctx
    );

    // Validate minimum output
    let output_amount = balance::value(&balance_y_out);
    assert!(output_amount >= min_output_amount, E_INSUFFICIENT_OUTPUT_AMOUNT);

    // Convert output balance to coin
    let output_coin = coin::from_balance(balance_y_out, ctx);
    balance::destroy_zero(balance_x_out); // Should be zero for x_for_y swaps

    // Return refunded input and output in (x, y) order
    (input_coin, output_coin)
}
```

#### Direct Pool Liquidity Modification Integration

Best practices for integrating with the core `pool::modify_liquidity` function for custom liquidity management:

```move
// Complete liquidity addition integration pattern
public fun add_liquidity_to_position<X, Y>(
    pool: &mut Pool<X, Y>,
    position: &mut Position,
    desired_amount_x: u64,
    desired_amount_y: u64,
    min_amount_x: u64,
    min_amount_y: u64,
    coin_x: Coin<X>,
    coin_y: Coin<Y>,
    versioned: &Versioned,
    clock: &Clock,
    ctx: &mut TxContext
): (Coin<X>, Coin<Y>) { // Returns refunded coins

    // Validate input amounts
    assert!(coin::value(&coin_x) >= desired_amount_x, E_INSUFFICIENT_INPUT_AMOUNT);
    assert!(coin::value(&coin_y) >= desired_amount_y, E_INSUFFICIENT_INPUT_AMOUNT);

    // Get current pool state for calculations
    let current_sqrt_price = pool::sqrt_price_current(pool);
    let current_liquidity = pool::liquidity(pool);
    let tick_lower = position::tick_lower_index(position);
    let tick_upper = position::tick_upper_index(position);

    // Calculate optimal liquidity amount based on desired token amounts
    let target_liquidity = calculate_liquidity_for_amounts(
        current_sqrt_price,
        tick_lower,
        tick_upper,
        desired_amount_x,
        desired_amount_y
    );

    // Prepare exact amounts needed (may be less than desired)
    // Convert tick boundaries to sqrt prices
    let sqrt_price_lower = tick_math::get_sqrt_price_at_tick(tick_lower);
    let sqrt_price_upper = tick_math::get_sqrt_price_at_tick(tick_upper);

    let (exact_amount_x, exact_amount_y) = liquidity_math::get_amounts_for_liquidity(
        current_sqrt_price,
        sqrt_price_lower,
        sqrt_price_upper,
        target_liquidity,
        true // add = true for adding liquidity
    );

    // Validate minimum amounts
    assert!(exact_amount_x >= min_amount_x, E_INSUFFICIENT_OUTPUT_AMOUNT);
    assert!(exact_amount_y >= min_amount_y, E_INSUFFICIENT_OUTPUT_AMOUNT);

    // Split exact amounts from input coins
    let balance_x_in = coin::into_balance(coin::split(&mut coin_x, exact_amount_x, ctx));
    let balance_y_in = coin::into_balance(coin::split(&mut coin_y, exact_amount_y, ctx));

    // Execute liquidity modification
    let liquidity_delta = i128::from(target_liquidity);
    let (actual_amount_x, actual_amount_y) = pool::modify_liquidity<X, Y>(
        pool,
        position,
        liquidity_delta,
        balance_x_in,
        balance_y_in,
        versioned,
        clock,
        ctx
    );

    // Validate actual amounts meet expectations
    assert!(actual_amount_x >= min_amount_x, E_INSUFFICIENT_LIQUIDITY_ADDED);
    assert!(actual_amount_y >= min_amount_y, E_INSUFFICIENT_LIQUIDITY_ADDED);

    // Return any remaining coins as refund
    (coin_x, coin_y)
}

// Advanced liquidity removal with precise control
public fun remove_liquidity_from_position<X, Y>(
    pool_registry: &mut PoolRegistry,
    pool: &mut Pool<X, Y>,
    position: &mut Position,
    liquidity_to_remove: u128,
    min_amount_x_out: u64,
    min_amount_y_out: u64,
    collect_fees: bool,
    versioned: &Versioned,
    clock: &Clock,
    ctx: &mut TxContext
): (Balance<X>, Balance<Y>) {

    // Validate position has enough liquidity
    let current_position_liquidity = position::liquidity(position);
    assert!(current_position_liquidity >= liquidity_to_remove, E_INSUFFICIENT_LIQUIDITY);

    // Get position details for calculations
    let tick_lower = position::tick_lower_index(position);
    let tick_upper = position::tick_upper_index(position);
    let current_sqrt_price = pool::sqrt_price_current(pool);

    // Calculate expected amounts to receive
    // Convert tick boundaries to sqrt prices
    let sqrt_price_lower = tick_math::get_sqrt_price_at_tick(tick_lower);
    let sqrt_price_upper = tick_math::get_sqrt_price_at_tick(tick_upper);

    let (expected_amount_x, expected_amount_y) = liquidity_math::get_amounts_for_liquidity(
        current_sqrt_price,
        sqrt_price_lower,
        sqrt_price_upper,
        liquidity_to_remove,
        false // add = false for removing liquidity
    );

    // Ensure expected amounts meet minimum requirements
    assert!(expected_amount_x >= min_amount_x_out, E_INSUFFICIENT_EXPECTED_OUTPUT);
    assert!(expected_amount_y >= min_amount_y_out, E_INSUFFICIENT_EXPECTED_OUTPUT);

    // Execute liquidity removal
    let liquidity_delta = i128::neg_from(liquidity_to_remove);
    let (actual_amount_x, actual_amount_y) = pool::modify_liquidity<X, Y>(
        pool,
        position,
        liquidity_delta,
        balance::zero<X>(), // No input when removing liquidity
        balance::zero<Y>(), // No input when removing liquidity
        versioned,
        clock,
        ctx
    );

    // Validate actual amounts meet minimum requirements
    assert!(actual_amount_x >= min_amount_x_out, E_INSUFFICIENT_OUTPUT_AMOUNT);
    assert!(actual_amount_y >= min_amount_y_out, E_INSUFFICIENT_OUTPUT_AMOUNT);

    // Collect fees if requested
    if (collect_fees) {
        let (collected_x, collected_y) = position_manager::collect<X, Y>(
            pool_registry,
            position,
            max_u64, // Collect all available fees
            max_u64, // Collect all available fees
            ctx
        );

        (collected_x, collected_y)
    } else {
        (
            balance::zero<X>(),
            balance::zero<Y>()
        )
    }
}

```

#### Position Fees and Rewards Management

Best practices for collecting fees and rewards from positions:

```move
// Optimized fee collection with threshold checking
public fun collect_fees<X, Y>(
    pool_registry: &mut PoolRegistry,
    position: &mut Position,
    versioned: &Versioned,
    ctx: &mut TxContext
): (Balance<X>, Balance<Y>) {
    let (fee_x, fee_y) = position_manager::collect<X, Y>(
        pool_registry,
        position,
        max_u64, // Collect all available fees
        max_u64, // Collect all available fees
        versioned,
        ctx
    );
    (fee_x, fee_y)
}

// Collect specific reward token type from position
public fun collect_position_reward<X, Y, RewardToken>(
    pool_registry: &mut PoolRegistry,
    position: &mut Position,
    versioned: &Versioned,
    clock: &Clock,
    ctx: &mut TxContext
): Coin<RewardToken> { // Returns collected reward coin

    // Collect the specific reward token type
    let collected_reward = position_manager::collect_pool_reward<X, Y, RewardToken>(
        pool_registry,
        position,
        max_u64, // Collect all available rewards
        versioned,
        clock,
        ctx
    );

    collected_reward
}
```

#### Position Monitoring

Best practices for getting position token amounts:

```move
// Get current token amounts in a position
public fun get_position_amounts<X, Y>(
    pool: &Pool<X, Y>,
    position: &Position
): (u64, u64) { // Returns (amount_x, amount_y)

    let tick_lower = position::tick_lower_index(position);
    let tick_upper = position::tick_upper_index(position);
    let current_sqrt_price = pool::sqrt_price_current(pool);
    let position_liquidity = position::liquidity(position);

    // Calculate current token amounts in the position
    if (position_liquidity > 0) {
        // Convert tick boundaries to sqrt prices
        let sqrt_price_lower = tick_math::get_sqrt_price_at_tick(tick_lower);
        let sqrt_price_upper = tick_math::get_sqrt_price_at_tick(tick_upper);

        liquidity_math::get_amounts_for_liquidity(
            current_sqrt_price,
            sqrt_price_lower,
            sqrt_price_upper,
            position_liquidity,
            false // add = false for getting amounts
        )
    } else {
        (0, 0)
    }
}
```

#### Multi-Hop Swaps

For token pairs without direct pools, implement multi-hop routing:

```move
// USDC -> SUI -> BTC (two-hop swap)
// Step 1: USDC -> SUI
let sui_balance = swap_router::swap_exact_x_to_y<USDC, SUI>(
    &mut usdc_sui_pool,
    usdc_in,
    min_sqrt_price_1,
    &versioned,
    &clock,
    ctx
);

// Step 2: SUI -> BTC
let btc_balance = swap_router::swap_exact_x_to_y<SUI, BTC>(
    &mut sui_btc_pool,
    coin::from_balance(sui_balance, ctx),
    min_sqrt_price_2,
    &versioned,
    &clock,
    ctx
);
```

#### Flash Loans Integration

Leverage flash loans for arbitrage and other strategies:

```move
// Flash loan pattern for arbitrage
public fun arbitrage_opportunity<X, Y>(
    pool: &mut Pool<X, Y>,
    flash_amount_x: u64,
    flash_amount_y: u64,
    versioned: &Versioned,
    ctx: &mut TxContext
): (Balance<X>, Balance<Y>) {
    // 1. Flash loan tokens from pool
    let (loan_x, loan_y, flash_receipt) = pool::flash<X, Y>(
        pool,
        flash_amount_x,
        flash_amount_y,
        versioned,
        ctx
    );

    // 2. Get debt amounts from receipt (includes fees)
    let (total_debt_x, total_debt_y) = pool::flash_receipt_debts(&flash_receipt);

    // 3. Execute arbitrage logic here
    // Example: swap tokens, interact with other protocols, etc.
    // ...your arbitrage logic...

    // 4. Prepare repayment (must include loan amount + fees)
    // Ensure you have enough to repay the debt
    let repay_x = loan_x; // Add your tokens if needed: balance::join(&mut loan_x, additional_x);
    let repay_y = loan_y; // Add your tokens if needed: balance::join(&mut loan_y, additional_y);

    // 5. Repay the flash loan with fees
    pool::repay<X, Y>(
        pool,
        flash_receipt,
        repay_x,
        repay_y,
        versioned,
        ctx
    );

    // 6. Return any profit
    (balance::zero<X>(), balance::zero<Y>())
}
```

## 🔮 Price Oracle System

FlowX CLMM includes a sophisticated time-weighted average price (TWAP) oracle system that provides reliable price feeds and historical data tracking. The oracle automatically records price and liquidity data with each swap, creating a decentralized price feed that follows the Uniswap V3 oracle design.

### 🎯 Oracle Features

| Feature                    | Description                                       |
| -------------------------- | ------------------------------------------------- |
| **TWAP Calculation**       | Time-weighted average prices over any time period |
| **Automated Recording**    | Automatic price updates with every transaction    |
| **Historical Data**        | Up to 1000 observations stored per pool           |
| **Manipulation Resistant** | Requires significant capital to manipulate prices |
| **Gas Efficient**          | Optimized storage and calculation algorithms      |

### 📊 Oracle Data Structure

Each oracle observation contains:

- **Timestamp (seconds)**: When the observation was recorded (in seconds, not milliseconds)
- **Tick Cumulative (I64)**: Cumulative sum of tick values over time (signed integer)
- **Seconds per Liquidity (u256)**: Time-weighted measure of liquidity depth
- **Initialization Status**: Whether the observation slot is active

### 🔧 Core Oracle Functions

#### Get Historical Price Data

```move
/// Get TWAP data for specified time periods
public fun observe<X, Y>(
    self: &Pool<X, Y>,
    seconds_agos: vector<u64>,
    clock: &Clock
): (vector<I64>, vector<u256>)
```

**Parameters:**

- `self`: Pool to query oracle data from
- `seconds_agos`: Array of time periods to look back (in seconds)
- `clock`: Clock object for current timestamp

**Returns:**

- `vector<I64>`: Tick cumulatives for each time period (signed integers)
- `vector<u256>`: Seconds per liquidity cumulatives for each time period

#### Increase Oracle Capacity

```move
/// Increase the maximum number of observations this pool will store
public fun increase_observation_cardinality_next<X, Y>(
    self: &mut Pool<X, Y>,
    observation_cardinality_next: u64,
    versioned: &Versioned,
    ctx: &TxContext
)
```

**Parameters:**

- `self`: Pool to increase capacity for
- `observation_cardinality_next`: New maximum number of observations (max 1000)
- `versioned`: Versioned object for package version validation
- `ctx`: Transaction context

### 💡 TWAP Calculation Examples

#### Basic TWAP Price Calculation

```move
use flowx_clmm::i64;
use flowx_clmm::i32;
use flowx_clmm::tick_math;

/// Calculate TWAP price over specified time period
public fun calculate_twap_price<X, Y>(
    pool: &Pool<X, Y>,
    period_seconds: u64,
    clock: &Clock
): u128 {
    // Get tick cumulatives for current time and period ago
    let seconds_agos = vector[0, period_seconds];
    let (tick_cumulatives, _) = pool.observe(seconds_agos, clock);

    let current_cumulative = *vector::borrow(&tick_cumulatives, 0);
    let past_cumulative = *vector::borrow(&tick_cumulatives, 1);

    // Calculate time-weighted average tick (handle signed arithmetic)
    let tick_delta = i64::sub(current_cumulative, past_cumulative);
    let average_tick_i64 = i64::div(tick_delta, i64::from(period_seconds));

    // Convert I64 to I32 for tick math
    let average_tick = if (i64::is_neg(average_tick_i64)) {
        i32::neg_from(i64::abs_u64(average_tick_i64))
    } else {
        i32::from_u64(i64::abs_u64(average_tick_i64))
    };

    // Convert tick to sqrt price
    tick_math::get_sqrt_price_at_tick(average_tick)
}

/// Get current oracle state information
public fun get_oracle_info<X, Y>(pool: &Pool<X, Y>): (u64, u64, u64) {
    (
        pool.observation_index(),           // Current observation index
        pool.observation_cardinality(),     // Number of populated observations
        pool.observation_cardinality_next() // Maximum observations capacity
    )
}
```

### Data Access Functions

```move
// Pool oracle state getters (read-only)
pool.observation_index();           // Current observation index: u64
pool.observation_cardinality();     // Active observations count: u64
pool.observation_cardinality_next(); // Maximum capacity: u64
pool.borrow_observations();         // Direct access to observations vector
```

### ⚠️ Error Handling

#### Common Error Scenarios

| Error Code                       | Description                           | Solution                              |
| -------------------------------- | ------------------------------------- | ------------------------------------- |
| `E_INSUFFICIENT_OUTPUT_AMOUNT`   | Slippage exceeded                     | Increase tolerance or wait            |
| `E_EXCESSIVE_INPUT_AMOUNT`       | Price moved unfavorably               | Retry with updated limits             |
| `E_ZERO_AMOUNT`                  | Cannot operate with zero amounts      | Provide non-zero amounts              |
| `E_NOT_EMPTY_POSITION`           | Position must be empty before closing | Remove all liquidity and collect fees |
| `E_PRICE_LIMIT_ALREADY_EXCEEDED` | Current price beyond specified limit  | Update price limit                    |
| `E_PRICE_LIMIT_OUT_OF_BOUNDS`    | Price limit outside valid range       | Use valid price range                 |

#### Error Handling and Edge Cases

**Common Error Scenarios:**

- `E_INSUFFICIENT_OUTPUT_AMOUNT`: Slippage exceeded, increase tolerance or wait
- `E_EXCESSIVE_INPUT_AMOUNT`: Price moved unfavorably, retry with updated limits
- `E_ZERO_AMOUNT`: Cannot operate with zero amounts
- `E_NOT_EMPTY_POSITION`: Position must be empty before closing (zero liquidity, zero coin owed, and zero reward)
- `E_PRICE_LIMIT_ALREADY_EXCEEDED`: The current price has already moved beyond the specified price limit before swap execution
- `E_PRICE_LIMIT_OUT_OF_BOUNDS`: The specified price limit is outside the valid range (below minimum or above maximum sqrt price)

## 🧮 Mathematical Libraries

FlowX CLMM includes optimized mathematical libraries for precise calculations:

### Core Math Libraries

| Library                | Purpose                        | Key Functions                                         |
| ---------------------- | ------------------------------ | ----------------------------------------------------- |
| `tick_math.move`       | Tick ↔ Price conversions       | `get_sqrt_price_at_tick`, `get_tick_at_sqrt_price`    |
| `sqrt_price_math.move` | Square root price calculations | `get_next_sqrt_price_from_amount`, `get_amount_delta` |
| `liquidity_math.move`  | Liquidity calculations         | `add_delta`, `get_amounts_for_liquidity`              |
| `full_math_u128.move`  | High-precision arithmetic      | `mul_div`, `mul_div_round_up`                         |
| `swap_math.move`       | Swap calculations              | `compute_swap_step`                                   |

## 🛠️ Development

### 🧪 Testing

#### Unit Tests

```bash
# Run all tests
sui move test

# Run with verbose output
sui move test --verbose

# Run with gas profiling
sui move test --gas-limit 1000000000
```

### 📝 Environment Configuration

#### Environment Variables

```bash
# .env.example
SUI_NETWORK=testnet
JSON_RPC_ENDPOINT=https://fullnode.testnet.sui.io:443  # RPC endpoint for Sui network (testnet/mainnet)
PRIVATE_KEY=your_private_key_here
```

## 📦 Deployment

### 🧪 Testnet Deployment

```bash
# 2. Build package
sui move build

# 3. Deploy to testnet
sui client publish --gas-budget 100000000
```

### 🚀 Mainnet Deployment

```bash
# 1. Switch to mainnet
sui client switch --env mainnet

# 2. Verify build
sui move build --verification

# 3. Deploy with higher gas budget
sui client publish --gas-budget 200000000
```
