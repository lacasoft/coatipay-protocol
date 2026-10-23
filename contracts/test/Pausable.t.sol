// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {Pausable} from "../src/Pausable.sol";
import {StakeManager} from "../src/StakeManager.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title  El guardian se transfiere en dos pasos (ADR-009 §6)
/// @notice Antes, `transferGuardian` cambiaba el guardian en el acto: una
///         dirección mal escrita lo perdía para siempre, en los tres contratos
///         a la vez si se rotaban juntos. Ahora el nuevo tiene que aceptar.
///         Se prueba a través de StakeManager, el derivado más simple.
contract PausableTwoStepTest is Test {
    StakeManager sm;
    address guardian = makeAddr("guardian");
    address nuevo = makeAddr("nuevoGuardian");

    function setUp() public {
        sm = new StakeManager(address(new MockUSDC()), guardian, makeAddr("treasury"));
    }

    function test_NadaCambiaHastaQueElNuevoAcepta() public {
        vm.expectEmit(true, true, false, false);
        emit Pausable.GuardianTransferStarted(guardian, nuevo);
        vm.prank(guardian);
        sm.transferGuardian(nuevo);

        assertEq(sm.guardian(), guardian);
        assertEq(sm.pendingGuardian(), nuevo);

        // El actual conserva sus poderes mientras tanto.
        vm.prank(guardian);
        sm.pause();

        vm.expectEmit(true, true, false, false);
        emit Pausable.GuardianTransferred(guardian, nuevo);
        vm.prank(nuevo);
        sm.acceptGuardian();

        assertEq(sm.guardian(), nuevo);
        assertEq(sm.pendingGuardian(), address(0));

        vm.prank(guardian);
        vm.expectRevert(Pausable.NotGuardian.selector);
        sm.unpause();
        vm.prank(nuevo);
        sm.unpause();
    }

    /// El caso que justifica el cambio: una dirección mal escrita.
    function test_UnaDireccionMalEscritaNuncaSeQuedaConNada() public {
        address malEscrita = address(0xDeAD0000000000000000000000000000000beef1);
        vm.prank(guardian);
        sm.transferGuardian(malEscrita);

        // Nadie más puede aceptar en su lugar...
        vm.prank(makeAddr("oportunista"));
        vm.expectRevert(Pausable.NotPendingGuardian.selector);
        sm.acceptGuardian();

        // ...y el guardian, que sigue siéndolo, corrige el error.
        vm.prank(guardian);
        sm.transferGuardian(nuevo);
        vm.prank(nuevo);
        sm.acceptGuardian();
        assertEq(sm.guardian(), nuevo);
    }

    function test_ProponerCeroCancela() public {
        vm.startPrank(guardian);
        sm.transferGuardian(nuevo);
        sm.transferGuardian(address(0));
        vm.stopPrank();

        vm.prank(nuevo);
        vm.expectRevert(Pausable.NotPendingGuardian.selector);
        sm.acceptGuardian();
        assertEq(sm.guardian(), guardian);
    }

    function test_Revert_SoloElGuardianPropone() public {
        vm.prank(nuevo);
        vm.expectRevert(Pausable.NotGuardian.selector);
        sm.transferGuardian(nuevo);
    }

    /// Sin propuesta en curso nadie puede aceptar, tampoco la dirección cero.
    function test_Revert_AceptarSinPropuesta() public {
        vm.prank(nuevo);
        vm.expectRevert(Pausable.NotPendingGuardian.selector);
        sm.acceptGuardian();
    }
}
