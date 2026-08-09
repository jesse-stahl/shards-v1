// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";

import { GeometricRendererV1 } from "./GeometricRendererV1.sol";
import { ShardConstantsV1 } from "./ShardConstantsV1.sol";
import { ShardErrorsV1 } from "./ShardErrorsV1.sol";
import { ShardHookV1 } from "./ShardHookV1.sol";
import { ShardNFTV1 } from "./ShardNFTV1.sol";
import { ShardTokenV1 } from "./ShardTokenV1.sol";
import { IShardNFTV1 } from "./interfaces/IShardNFTV1.sol";

/// @title ShardLaunchFactoryV1
/// @notice Atomically deploys and initialises a Shards collection from hash-pinned hook code.
contract ShardLaunchFactoryV1 {
    /// @param renderer Art contract for this collection. `address(0)` means "use the factory's own
    ///        shared {GeometricRendererV1}", which is the canonical choice; any other address must
    ///        already have code. Whatever is chosen is resolved once and bound into both the token
    ///        salt and the NFT init code, so a collection's art is fixed at launch.
    struct LaunchParams {
        int24 tickLower;
        int24 tickBand;
        int24 tickUpper;
        uint160 startSqrtPriceX96;
        address renderer;
        string tokenName;
        string tokenSymbol;
        string nftName;
        string nftSymbol;
    }

    struct ConfigurationData {
        uint256 chainId;
        address factory;
        address poolManager;
        address renderer;
        address launcherFeeRecipient;
        address builderFeeRecipient;
        address shard;
        address hook;
        address nft;
        int24 tickLower;
        int24 tickBand;
        int24 tickUpper;
        uint160 startSqrtPriceX96;
        bytes32 tokenNameHash;
        bytes32 tokenSymbolHash;
        bytes32 nftNameHash;
        bytes32 nftSymbolHash;
        bytes32 tokenSalt;
        bytes32 effectiveTokenSalt;
        bytes32 hookSalt;
        bytes32 hookCreationCodeHash;
    }

    struct LaunchAddresses {
        address hook;
        address shard;
        address nft;
    }

    error ZeroHookCodeHash();
    error WrongHookCode(bytes32 expected, bytes32 actual);
    error InvalidHookFlags(address predictedHook, uint160 expected, uint160 actual);
    error AddressOccupied(address predicted);
    error TokenTransferFailed();
    error FactoryRetainedShard(uint256 balance);
    error EmptyMetadata();
    error MetadataTooLong(uint256 length, uint256 maxLength);
    error RendererHasNoCode(address renderer);
    error IllegalMetadataCharacter(uint256 index, bytes1 character);

    uint160 public constant ALL_HOOK_MASK = uint160((1 << 14) - 1);
    uint160 public constant REQUIRED_HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    /// @notice Programmable's fixed 0.10% ("launcher") recipient. Bound immutably to the canonical
    ///         Programmable address for every launch — the factory cannot route it anywhere else.
    address public constant launcherFeeRecipient = 0x4957f49620AFf3Adbbe8195a4f633E49cc93376c;

    /// @notice The fixed 0.80%-adjacent "builder" recipient. Deliberately a constant rather than a
    ///         launch input: every collection this factory produces pays the same builder, and no
    ///         caller can point that share elsewhere. It is still rotatable AFTER launch through
    ///         {ShardFeeDistributorV1.setBuilderFeeRecipient}, which only the current builder may
    ///         call — "hardcoded" here means "not a per-launch choice", not "immutable forever".
    address public constant builderFeeRecipient = 0xceeBB3A6543CeBEB2ED66963897A0abEA52A50cC;

    /// @dev Metadata length caps. Unbounded strings would make the token and NFT init code unbounded,
    ///      which inflates the hook-salt mining cost and pushes against the EIP-3860 initcode limit.
    uint256 public constant MAX_NAME_BYTES = 32;
    uint256 public constant MAX_SYMBOL_BYTES = 12;

    IPoolManager public immutable poolManager;
    GeometricRendererV1 public immutable renderer;
    bytes32 public immutable hookCreationCodeHash;

    mapping(address hook => bytes32 configurationHash) public configurationHashOf;

    event ShardLaunched(
        address indexed hook,
        address indexed shard,
        address indexed nft,
        bytes32 tokenSalt,
        bytes32 hookSalt,
        address builderFeeRecipient,
        address renderer,
        bytes32 configurationHash
    );

    constructor(IPoolManager poolManager_, bytes32 hookCreationCodeHash_) {
        if (address(poolManager_) == address(0)) revert ShardErrorsV1.ZeroAddress();
        if (hookCreationCodeHash_ == bytes32(0)) revert ZeroHookCodeHash();
        poolManager = poolManager_;
        hookCreationCodeHash = hookCreationCodeHash_;
        renderer = new GeometricRendererV1();
    }

    /// @notice The renderer a launch will actually use: the factory's shared one when the caller
    ///         passes `address(0)`, otherwise the caller's choice.
    function resolveRenderer(address requested) public view returns (address) {
        return requested == address(0) ? address(renderer) : requested;
    }

    /// @dev Every encoded word is fixed-width ON PURPOSE — the strings enter as digests, not inline.
    ///      The mining loop preallocates this preimage once and rewrites only word 1 (the hook salt)
    ///      per candidate; a variable-width field would break that layout and the loop would start
    ///      allocating per iteration. `builderFeeRecipient` is absent because it is now a constant
    ///      and so cannot distinguish two launches; the metadata and renderer take over that job.
    function effectiveTokenSalt(bytes32 tokenSalt, bytes32 hookSalt, LaunchParams calldata params)
        public
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                tokenSalt,
                hookSalt,
                params.tickLower,
                params.tickBand,
                params.tickUpper,
                params.startSqrtPriceX96,
                resolveRenderer(params.renderer),
                keccak256(bytes(params.tokenName)),
                keccak256(bytes(params.tokenSymbol)),
                keccak256(bytes(params.nftName)),
                keccak256(bytes(params.nftSymbol))
            )
        );
    }

    /// @notice Init code for this launch's ERC-20, creation code plus its name/symbol arguments.
    function tokenInitCode(LaunchParams calldata params) public pure returns (bytes memory) {
        return bytes.concat(type(ShardTokenV1).creationCode, abi.encode(params.tokenName, params.tokenSymbol));
    }

    function predictToken(bytes32 tokenSalt, bytes32 hookSalt, LaunchParams calldata params)
        public
        view
        returns (address)
    {
        return Create2.computeAddress(effectiveTokenSalt(tokenSalt, hookSalt, params), keccak256(tokenInitCode(params)));
    }

    function hookInitCode(bytes calldata hookCreationCode, address shard, LaunchParams calldata params)
        public
        view
        returns (bytes memory)
    {
        return bytes.concat(
            hookCreationCode,
            abi.encode(
                poolManager,
                ShardTokenV1(shard),
                params.tickLower,
                params.tickBand,
                params.tickUpper,
                params.startSqrtPriceX96,
                address(this),
                launcherFeeRecipient,
                builderFeeRecipient
            )
        );
    }

    function hookInitCodeHash(bytes calldata hookCreationCode, address shard, LaunchParams calldata params)
        public
        view
        returns (bytes32)
    {
        return keccak256(hookInitCode(hookCreationCode, shard, params));
    }

    function predictHook(bytes32 hookSalt, bytes calldata hookCreationCode, address shard, LaunchParams calldata params)
        public
        view
        returns (address)
    {
        return Create2.computeAddress(hookSalt, hookInitCodeHash(hookCreationCode, shard, params));
    }

    /// @notice Init code for this launch's ERC-721: creation code plus hook, resolved renderer and
    ///         its own name/symbol. Public so the launch script and test miner derive it from here
    ///         rather than keeping a third private copy that could drift.
    function nftInitCode(address hook, LaunchParams calldata params) public view returns (bytes memory) {
        return bytes.concat(
            type(ShardNFTV1).creationCode,
            abi.encode(hook, resolveRenderer(params.renderer), params.nftName, params.nftSymbol)
        );
    }

    function predictNFT(address hook, LaunchParams calldata params) public view returns (address) {
        return Create2.computeAddress(_nftSalt(hook), keccak256(nftInitCode(hook, params)));
    }

    function launch(bytes32 tokenSalt, bytes32 hookSalt, bytes calldata hookCreationCode, LaunchParams calldata params)
        external
        returns (address hook, address shard, address nft)
    {
        _validateHookCode(hookCreationCode);
        _validateParams(params);
        LaunchAddresses memory deployed = _deploy(tokenSalt, hookSalt, hookCreationCode, params);
        bytes32 configurationHash =
            computeConfigurationHash(deployed.hook, deployed.shard, deployed.nft, tokenSalt, hookSalt, params);
        configurationHashOf[deployed.hook] = configurationHash;
        emit ShardLaunched(
            deployed.hook,
            deployed.shard,
            deployed.nft,
            tokenSalt,
            hookSalt,
            builderFeeRecipient,
            resolveRenderer(params.renderer),
            configurationHash
        );
        return (deployed.hook, deployed.shard, deployed.nft);
    }

    function _deploy(bytes32 tokenSalt, bytes32 hookSalt, bytes calldata hookCreationCode, LaunchParams calldata params)
        private
        returns (LaunchAddresses memory deployed)
    {
        deployed.shard = predictToken(tokenSalt, hookSalt, params);
        deployed.hook = predictHook(hookSalt, hookCreationCode, deployed.shard, params);
        deployed.nft = predictNFT(deployed.hook, params);
        uint160 actualFlags = uint160(deployed.hook) & ALL_HOOK_MASK;
        if (actualFlags != REQUIRED_HOOK_FLAGS) {
            revert InvalidHookFlags(deployed.hook, REQUIRED_HOOK_FLAGS, actualFlags);
        }
        if (deployed.shard.code.length != 0) revert AddressOccupied(deployed.shard);
        if (deployed.hook.code.length != 0) revert AddressOccupied(deployed.hook);
        if (deployed.nft.code.length != 0) revert AddressOccupied(deployed.nft);

        deployed.shard = Create2.deploy(0, effectiveTokenSalt(tokenSalt, hookSalt, params), tokenInitCode(params));
        bytes memory initCode = hookInitCode(hookCreationCode, deployed.shard, params);
        deployed.hook = Create2.deploy(0, hookSalt, initCode);
        deployed.nft = Create2.deploy(0, _nftSalt(deployed.hook), nftInitCode(deployed.hook, params));

        ShardHookV1 deployedHook = ShardHookV1(payable(deployed.hook));
        deployedHook.setNFT(IShardNFTV1(deployed.nft));
        ShardTokenV1 deployedShard = ShardTokenV1(deployed.shard);
        if (!deployedShard.transfer(deployed.hook, deployedShard.totalSupply())) revert TokenTransferFailed();
        deployedHook.initialise();

        uint256 retained = deployedShard.balanceOf(address(this));
        if (retained != 0) revert FactoryRetainedShard(retained);
    }

    function _validateHookCode(bytes calldata hookCreationCode) private view {
        bytes32 actualHookCodeHash = keccak256(hookCreationCode);
        if (actualHookCodeHash != hookCreationCodeHash) {
            revert WrongHookCode(hookCreationCodeHash, actualHookCodeHash);
        }
    }

    function _nftSalt(address hook) private pure returns (bytes32) {
        return keccak256(abi.encode(hook));
    }

    function computeConfigurationHash(
        address hook,
        address shard,
        address nft,
        bytes32 tokenSalt,
        bytes32 hookSalt,
        LaunchParams calldata params
    ) public view returns (bytes32) {
        ConfigurationData memory data;
        data.chainId = block.chainid;
        data.factory = address(this);
        data.poolManager = address(poolManager);
        data.renderer = resolveRenderer(params.renderer);
        data.launcherFeeRecipient = launcherFeeRecipient;
        data.builderFeeRecipient = builderFeeRecipient;
        data.shard = shard;
        data.hook = hook;
        data.nft = nft;
        data.tickLower = params.tickLower;
        data.tickBand = params.tickBand;
        data.tickUpper = params.tickUpper;
        data.startSqrtPriceX96 = params.startSqrtPriceX96;
        data.tokenNameHash = keccak256(bytes(params.tokenName));
        data.tokenSymbolHash = keccak256(bytes(params.tokenSymbol));
        data.nftNameHash = keccak256(bytes(params.nftName));
        data.nftSymbolHash = keccak256(bytes(params.nftSymbol));
        data.tokenSalt = tokenSalt;
        data.effectiveTokenSalt = effectiveTokenSalt(tokenSalt, hookSalt, params);
        data.hookSalt = hookSalt;
        data.hookCreationCodeHash = hookCreationCodeHash;
        return keccak256(abi.encode(data));
    }

    function _validateParams(LaunchParams calldata params) private view {
        if (params.renderer != address(0) && params.renderer.code.length == 0) {
            revert RendererHasNoCode(params.renderer);
        }
        _validateMetadata(params.tokenName, MAX_NAME_BYTES);
        _validateMetadata(params.tokenSymbol, MAX_SYMBOL_BYTES);
        _validateMetadata(params.nftName, MAX_NAME_BYTES);
        _validateMetadata(params.nftSymbol, MAX_SYMBOL_BYTES);
        int24 spacing = ShardConstantsV1.TICK_SPACING;
        if (
            params.tickLower < TickMath.minUsableTick(spacing) || params.tickUpper > TickMath.maxUsableTick(spacing)
                || params.tickLower >= params.tickBand || params.tickBand >= params.tickUpper
                || params.tickLower % spacing != 0 || params.tickBand % spacing != 0 || params.tickUpper % spacing != 0
        ) {
            revert ShardErrorsV1.InvalidTickRange();
        }
        uint160 start = params.startSqrtPriceX96;
        if (
            start < TickMath.MIN_SQRT_PRICE || start >= TickMath.MAX_SQRT_PRICE
                || TickMath.getTickAtSqrtPrice(start) < params.tickUpper
        ) {
            revert ShardErrorsV1.InvalidStartPrice();
        }
    }

    /// @dev Length AND character validation. The character rule is load-bearing rather than
    ///      cosmetic: {ShardNFTV1.tokenURI} interpolates the collection name straight into a JSON
    ///      string, so a name carrying a double quote or a backslash could break out of that string
    ///      and forge the rest of the metadata document. Rejecting those two bytes plus the control
    ///      range at launch is what lets the token URI skip escaping entirely. DEL (0x7F) is allowed
    ///      through as it cannot terminate a JSON string; everything below 0x20 cannot appear in one
    ///      unescaped and is refused.
    function _validateMetadata(string calldata value, uint256 maxBytes) private pure {
        bytes calldata raw = bytes(value);
        uint256 length = raw.length;
        if (length == 0) revert EmptyMetadata();
        if (length > maxBytes) revert MetadataTooLong(length, maxBytes);
        for (uint256 i; i < length; ++i) {
            bytes1 c = raw[i];
            if (c == 0x22 || c == 0x5C || c < 0x20) revert IllegalMetadataCharacter(i, c);
        }
    }
}
