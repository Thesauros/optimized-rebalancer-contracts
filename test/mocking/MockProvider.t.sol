// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test} from "forge-std/Test.sol";
import {BaseMockProvider, MockProviderA, MockProviderB, MockProviderC, InvalidProvider} from "../../contracts/mocks/MockProvider.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {Vault} from "../../contracts/base/Vault.sol";
import {IProvider} from "../../contracts/interfaces/IProvider.sol";
import {IVault} from "../../contracts/interfaces/IVault.sol";

/**
 * @title MockVault
 * @dev A simple mock vault that only implements the asset() function needed for testing
 */
contract MockVault {
    address public immutable asset;
    
    constructor(address _asset) {
        asset = _asset;
    }
}

contract MockProviderTests is Test {
    BaseMockProvider public baseProvider;
    MockProviderA public providerA;
    MockProviderB public providerB;
    MockProviderC public providerC;
    InvalidProvider public invalidProvider;
    MockERC20 public mockToken;
    MockVault public mockVault;

    function setUp() public {
        baseProvider = new BaseMockProvider();
        providerA = new MockProviderA();
        providerB = new MockProviderB();
        providerC = new MockProviderC();
        invalidProvider = new InvalidProvider();
        
        mockToken = new MockERC20("Mock Token", "MTK", 18);
        
        // Create a proper mock vault that returns the mock token as asset
        mockVault = new MockVault(address(mockToken));
    }

    // =========================================
    // BaseMockProvider tests
    // =========================================

    function testBaseProviderGetIdentifier() public view {
        string memory identifier = baseProvider.getIdentifier();
        assertEq(identifier, "Base_Provider");
    }

    function testBaseProviderGetSource() public view {
        address keyOne = address(0x123);
        address keyTwo = address(0x456);
        address keyThree = address(0x789);
        
        address source = baseProvider.getSource(keyOne, keyTwo, keyThree);
        assertEq(source, keyOne);
    }

    function testBaseProviderGetDepositRate() public view {
        uint256 rate = baseProvider.getDepositRate(IVault(address(mockVault)));
        assertEq(rate, 1e27);
    }

    function testBaseProviderGetDepositBalance() public view {
        address user = address(0x123);
        uint256 balance = baseProvider.getDepositBalance(user, IVault(address(mockVault)));
        assertEq(balance, 0); // Should return 0 by default
    }

    function testBaseProviderDeposit() public {
        uint256 amount = 1000e18;
        
        // Mock the vault.asset() call to return mockToken address
        vm.mockCall(
            address(mockVault),
            abi.encodeWithSelector(bytes4(keccak256("asset()"))),
            abi.encode(address(mockToken))
        );
        
        // Mock the token.depositTokens call to return true
        vm.mockCall(
            address(mockToken),
            abi.encodeWithSelector(MockERC20.depositTokens.selector, address(mockVault), amount, "Base_Provider"),
            abi.encode(true)
        );
        
        bool success = baseProvider.deposit(amount, IVault(address(mockVault)));
        assertTrue(success);
    }

    function testBaseProviderDepositFails() public {
        uint256 amount = 1000e18;
        
        // Mock the vault.asset() call to return mockToken address
        vm.mockCall(
            address(mockVault),
            abi.encodeWithSelector(bytes4(keccak256("asset()"))),
            abi.encode(address(mockToken))
        );
        
        // Mock the token.depositTokens call to return false
        vm.mockCall(
            address(mockToken),
            abi.encodeWithSelector(MockERC20.depositTokens.selector, address(mockVault), amount, "Base_Provider"),
            abi.encode(false)
        );
        
        bool success = baseProvider.deposit(amount, IVault(address(mockVault)));
        assertFalse(success);
    }

    function testBaseProviderDepositReverts() public {
        uint256 amount = 1000e18;
        
        // Mock the vault.asset() call to return mockToken address
        vm.mockCall(
            address(mockVault),
            abi.encodeWithSelector(bytes4(keccak256("asset()"))),
            abi.encode(address(mockToken))
        );
        
        // Mock the token.depositTokens call to revert
        vm.mockCall(
            address(mockToken),
            abi.encodeWithSelector(MockERC20.depositTokens.selector, address(mockVault), amount, "Base_Provider"),
            abi.encode()
        );
        vm.mockCallRevert(
            address(mockToken),
            abi.encodeWithSelector(MockERC20.depositTokens.selector, address(mockVault), amount, "Base_Provider"),
            abi.encode("Mock revert")
        );
        
        bool success = baseProvider.deposit(amount, IVault(address(mockVault)));
        assertFalse(success); // Should return false when call reverts
    }

    function testBaseProviderWithdraw() public {
        uint256 amount = 1000e18;
        
        // Mock the vault.asset() call to return mockToken address
        vm.mockCall(
            address(mockVault),
            abi.encodeWithSelector(bytes4(keccak256("asset()"))),
            abi.encode(address(mockToken))
        );
        
        // Mock the token.withdrawTokens call to return true
        vm.mockCall(
            address(mockToken),
            abi.encodeWithSelector(MockERC20.withdrawTokens.selector, address(mockVault), amount, "Base_Provider"),
            abi.encode(true)
        );
        
        bool success = baseProvider.withdraw(amount, IVault(address(mockVault)));
        assertTrue(success);
    }

    function testBaseProviderWithdrawFails() public {
        uint256 amount = 1000e18;
        
        // Mock the vault.asset() call to return mockToken address
        vm.mockCall(
            address(mockVault),
            abi.encodeWithSelector(bytes4(keccak256("asset()"))),
            abi.encode(address(mockToken))
        );
        
        // Mock the token.withdrawTokens call to return false
        vm.mockCall(
            address(mockToken),
            abi.encodeWithSelector(MockERC20.withdrawTokens.selector, address(mockVault), amount, "Base_Provider"),
            abi.encode(false)
        );
        
        bool success = baseProvider.withdraw(amount, IVault(address(mockVault)));
        assertFalse(success);
    }

    function testBaseProviderWithdrawReverts() public {
        uint256 amount = 1000e18;
        
        // Mock the vault.asset() call to return mockToken address
        vm.mockCall(
            address(mockVault),
            abi.encodeWithSelector(bytes4(keccak256("asset()"))),
            abi.encode(address(mockToken))
        );
        
        // Mock the token.withdrawTokens call to revert
        vm.mockCallRevert(
            address(mockToken),
            abi.encodeWithSelector(MockERC20.withdrawTokens.selector, address(mockVault), amount, "Base_Provider"),
            abi.encode("Mock revert")
        );
        
        bool success = baseProvider.withdraw(amount, IVault(address(mockVault)));
        assertFalse(success); // Should return false when call reverts
    }

    // =========================================
    // MockProviderA tests
    // =========================================

    function testProviderAGetIdentifier() public view {
        string memory identifier = providerA.getIdentifier();
        assertEq(identifier, "Provider_A");
    }

    function testProviderADeposit() public {
        uint256 amount = 1000e18;
        
        // Mock the vault.asset() call to return mockToken address
        vm.mockCall(
            address(mockVault),
            abi.encodeWithSelector(bytes4(keccak256("asset()"))),
            abi.encode(address(mockToken))
        );
        
        // Mock the token.depositTokens call to return true
        vm.mockCall(
            address(mockToken),
            abi.encodeWithSelector(MockERC20.depositTokens.selector, address(mockVault), amount, "Provider_A"),
            abi.encode(true)
        );
        
        bool success = providerA.deposit(amount, IVault(address(mockVault)));
        assertTrue(success);
    }

    function testProviderAWithdraw() public {
        uint256 amount = 1000e18;
        
        // Mock the vault.asset() call to return mockToken address
        vm.mockCall(
            address(mockVault),
            abi.encodeWithSelector(bytes4(keccak256("asset()"))),
            abi.encode(address(mockToken))
        );
        
        // Mock the token.withdrawTokens call to return true
        vm.mockCall(
            address(mockToken),
            abi.encodeWithSelector(MockERC20.withdrawTokens.selector, address(mockVault), amount, "Provider_A"),
            abi.encode(true)
        );
        
        bool success = providerA.withdraw(amount, IVault(address(mockVault)));
        assertTrue(success);
    }

    // =========================================
    // MockProviderB tests
    // =========================================

    function testProviderBGetIdentifier() public view {
        string memory identifier = providerB.getIdentifier();
        assertEq(identifier, "Provider_B");
    }

    function testProviderBDeposit() public {
        uint256 amount = 1000e18;
        
        // Mock the vault.asset() call to return mockToken address
        vm.mockCall(
            address(mockVault),
            abi.encodeWithSelector(bytes4(keccak256("asset()"))),
            abi.encode(address(mockToken))
        );
        
        // Mock the token.depositTokens call to return true
        vm.mockCall(
            address(mockToken),
            abi.encodeWithSelector(MockERC20.depositTokens.selector, address(mockVault), amount, "Provider_B"),
            abi.encode(true)
        );
        
        bool success = providerB.deposit(amount, IVault(address(mockVault)));
        assertTrue(success);
    }

    // =========================================
    // MockProviderC tests
    // =========================================

    function testProviderCGetIdentifier() public view {
        string memory identifier = providerC.getIdentifier();
        assertEq(identifier, "Provider_C");
    }

    function testProviderCDeposit() public {
        uint256 amount = 1000e18;
        
        // Mock the vault.asset() call to return mockToken address
        vm.mockCall(
            address(mockVault),
            abi.encodeWithSelector(bytes4(keccak256("asset()"))),
            abi.encode(address(mockToken))
        );
        
        // Mock the token.depositTokens call to return true
        vm.mockCall(
            address(mockToken),
            abi.encodeWithSelector(MockERC20.depositTokens.selector, address(mockVault), amount, "Provider_C"),
            abi.encode(true)
        );
        
        bool success = providerC.deposit(amount, IVault(address(mockVault)));
        assertTrue(success);
    }

    // =========================================
    // InvalidProvider tests
    // =========================================

    function testInvalidProviderGetIdentifier() public view {
        string memory identifier = invalidProvider.getIdentifier();
        assertEq(identifier, "Invalid_Provider");
    }

    function testInvalidProviderDeposit() public {
        uint256 amount = 1000e18;
        
        // Mock the vault.asset() call to return mockToken address
        vm.mockCall(
            address(mockVault),
            abi.encodeWithSelector(bytes4(keccak256("asset()"))),
            abi.encode(address(mockToken))
        );
        
        // Mock the token.depositTokens call to return true
        vm.mockCall(
            address(mockToken),
            abi.encodeWithSelector(MockERC20.depositTokens.selector, address(mockVault), amount, "Invalid_Provider"),
            abi.encode(true)
        );
        
        bool success = invalidProvider.deposit(amount, IVault(address(mockVault)));
        assertTrue(success);
    }

    // =========================================
    // edge cases
    // =========================================

    function testGetSourceWithZeroAddress() public view {
        address source = baseProvider.getSource(address(0), address(0x456), address(0x789));
        assertEq(source, address(0));
    }

    function testGetDepositRateWithZeroVault() public view {
        uint256 rate = baseProvider.getDepositRate(IVault(address(0)));
        assertEq(rate, 1e27);
    }

    function testGetDepositBalanceWithZeroUser() public view {
        uint256 balance = baseProvider.getDepositBalance(address(0), IVault(address(mockVault)));
        assertEq(balance, 0);
    }

    function testDepositWithZeroAmount() public {
        uint256 amount = 0;
        
        // Mock the vault.asset() call to return mockToken address
        vm.mockCall(
            address(mockVault),
            abi.encodeWithSelector(bytes4(keccak256("asset()"))),
            abi.encode(address(mockToken))
        );
        
        // Mock the token.depositTokens call to return true
        vm.mockCall(
            address(mockToken),
            abi.encodeWithSelector(MockERC20.depositTokens.selector, address(mockVault), amount, "Base_Provider"),
            abi.encode(true)
        );
        
        bool success = baseProvider.deposit(amount, IVault(address(mockVault)));
        assertTrue(success);
    }

    function testWithdrawWithZeroAmount() public {
        uint256 amount = 0;
        
        // Mock the vault.asset() call to return mockToken address
        vm.mockCall(
            address(mockVault),
            abi.encodeWithSelector(bytes4(keccak256("asset()"))),
            abi.encode(address(mockToken))
        );
        
        // Mock the token.withdrawTokens call to return true
        vm.mockCall(
            address(mockToken),
            abi.encodeWithSelector(MockERC20.withdrawTokens.selector, address(mockVault), amount, "Base_Provider"),
            abi.encode(true)
        );
        
        bool success = baseProvider.withdraw(amount, IVault(address(mockVault)));
        assertTrue(success);
    }

    // =========================================
    // fuzz testing
    // =========================================

    function testFuzzGetSource(address keyOne, address keyTwo, address keyThree) public view {
        address source = baseProvider.getSource(keyOne, keyTwo, keyThree);
        assertEq(source, keyOne);
    }

    function testFuzzGetDepositRate(IVault vault) public view {
        uint256 rate = baseProvider.getDepositRate(vault);
        assertEq(rate, 1e27);
    }

    function testFuzzGetDepositBalance(address user) public view {
        uint256 balance = baseProvider.getDepositBalance(user, IVault(address(mockVault)));
        // Balance should be non-negative
        assertTrue(balance >= 0);
    }
}
