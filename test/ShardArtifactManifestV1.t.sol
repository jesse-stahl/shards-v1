// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

/// @notice Locks the published artifact tables to the bytes this repository actually compiles.
///
/// @dev `spec/shards-v1.json` and `releases/shards-v1/mainnet-manifest.json` both publish a size and
///      hash for every deployed artifact. Those numbers are release evidence: a reviewer reads them
///      instead of rebuilding, and the pinned CREATE2 plan is only reproducible if they describe the
///      exact reviewed build. Nothing in a normal edit-and-test loop notices when they fall behind,
///      which is how they drifted before — the factory grew by more than two kilobytes while the
///      table still reported the old figure.
///
///      This suite closes that gap by rereading both files and comparing every entry against the
///      compiled artifact, so a source change that moves a byte fails here until the tables are
///      regenerated. Sizes and hashes come from `vm.getCode` / `vm.getDeployedCode`, which read the
///      same artifacts `forge inspect` prints.
contract ShardArtifactManifestV1Test is Test {
    string internal spec;
    string internal manifest;

    /// @dev Artifact identifier paired with the key each file records it under.
    struct Artifact {
        string contractId;
        string specPrefix;
        string manifestKey;
    }

    function setUp() public {
        spec = vm.readFile("spec/shards-v1.json");
        manifest = vm.readFile("releases/shards-v1/mainnet-manifest.json");
    }

    function _artifacts() internal pure returns (Artifact[5] memory) {
        return [
            Artifact("ShardHookV1.sol:ShardHookV1", "hook", "hookTemplate"),
            Artifact("ShardLaunchFactoryV1.sol:ShardLaunchFactoryV1", "factory", "factory"),
            Artifact("GeometricRendererV1.sol:GeometricRendererV1", "renderer", "renderer"),
            Artifact("ShardNFTV1.sol:ShardNFTV1", "nft", "nftTemplate"),
            Artifact("ShardTokenV1.sol:ShardTokenV1", "shard", "shard")
        ];
    }

    function test_specBuildTableMatchesCompiledArtifacts() public view {
        Artifact[5] memory artifacts = _artifacts();
        for (uint256 i; i < artifacts.length; ++i) {
            Artifact memory a = artifacts[i];
            uint256 runtime = vm.getDeployedCode(a.contractId).length;
            uint256 creation = vm.getCode(a.contractId).length;

            assertEq(
                vm.parseJsonUint(spec, string.concat("$.build.", a.specPrefix, "RuntimeBytes")),
                runtime,
                string.concat("spec ", a.specPrefix, "RuntimeBytes is stale")
            );
            assertEq(
                vm.parseJsonUint(spec, string.concat("$.build.", a.specPrefix, "CreationCodeBytes")),
                creation,
                string.concat("spec ", a.specPrefix, "CreationCodeBytes is stale")
            );
        }
    }

    function test_manifestArtifactCodeMatchesCompiledArtifacts() public view {
        Artifact[5] memory artifacts = _artifacts();
        for (uint256 i; i < artifacts.length; ++i) {
            Artifact memory a = artifacts[i];
            bytes memory runtime = vm.getDeployedCode(a.contractId);
            bytes memory creation = vm.getCode(a.contractId);
            string memory base = string.concat("$.artifactCode.", a.manifestKey, ".");

            assertEq(
                vm.parseJsonUint(manifest, string.concat(base, "runtimeBytes")),
                runtime.length,
                string.concat("manifest ", a.manifestKey, ".runtimeBytes is stale")
            );
            assertEq(
                vm.parseJsonUint(manifest, string.concat(base, "creationCodeBytes")),
                creation.length,
                string.concat("manifest ", a.manifestKey, ".creationCodeBytes is stale")
            );
            assertEq(
                vm.parseJsonBytes32(manifest, string.concat(base, "runtimeCodeHash")),
                keccak256(runtime),
                string.concat("manifest ", a.manifestKey, ".runtimeCodeHash is stale")
            );
            assertEq(
                vm.parseJsonBytes32(manifest, string.concat(base, "creationCodeHash")),
                keccak256(creation),
                string.concat("manifest ", a.manifestKey, ".creationCodeHash is stale")
            );
        }
    }

    /// @dev The hook creation-code hash is load-bearing twice over: the factory pins it at
    ///      construction and refuses any other bytes, and the whole CREATE2 plan is mined against it.
    function test_pinnedHookCreationCodeHashMatchesTheCompiledHook() public view {
        bytes32 compiled = keccak256(vm.getCode("ShardHookV1.sol:ShardHookV1"));
        assertEq(
            vm.parseJsonBytes32(manifest, "$.candidatePlan.hookCreationCodeHash"),
            compiled,
            "candidatePlan.hookCreationCodeHash does not describe this build"
        );
        assertEq(
            vm.parseJsonBytes32(manifest, "$.artifactCode.hookTemplate.creationCodeHash"),
            compiled,
            "artifactCode.hookTemplate.creationCodeHash does not describe this build"
        );
    }

    /// @dev Both limits are declared in the spec rather than assumed, so this also catches a build
    ///      that silently drifts past them. `ShardHookV1` runs within a few hundred bytes of EIP-170.
    function test_everyArtifactStaysWithinTheDeclaredLimits() public view {
        uint256 runtimeLimit = vm.parseJsonUint(spec, "$.build.eip170LimitBytes");
        uint256 initcodeLimit = vm.parseJsonUint(spec, "$.build.eip3860InitcodeLimitBytes");
        Artifact[5] memory artifacts = _artifacts();
        for (uint256 i; i < artifacts.length; ++i) {
            Artifact memory a = artifacts[i];
            assertLt(
                vm.getDeployedCode(a.contractId).length,
                runtimeLimit,
                string.concat(a.specPrefix, " runtime exceeds the declared EIP-170 limit")
            );
            assertLt(
                vm.getCode(a.contractId).length,
                initcodeLimit,
                string.concat(a.specPrefix, " creation code exceeds the declared EIP-3860 limit")
            );
        }
    }
}
