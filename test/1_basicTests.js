// const { BN, constants, expectEvent, expectRevert, time } = require('openzeppelin-test-helpers');
const { BN, time } = require('openzeppelin-test-helpers');
var jsonfile = require('jsonfile');
const { assert } = require('chai');
const { web3 } = require('openzeppelin-test-helpers/src/setup');


const Votium = artifacts.require("Votium");

const ERC20 = artifacts.require("IERC20");

const addAccount = async (address) => {
  return new Promise((resolve, reject) => {
    web3.currentProvider.send(
      {
        jsonrpc: "2.0",
        method: "evm_addAccount",
        params: [address, "passphrase"],
        id: new Date().getTime(),
      },
      (err, result) => {
        if (err) {
          return reject(err);
        }
        return resolve(result);
      }
    );
  });
};

const unlockAccount = async (address) => {
  await addAccount(address);
  return new Promise((resolve, reject) => {
    web3.currentProvider.send(
      {
        jsonrpc: "2.0",
        method: "personal_unlockAccount",
        params: [address, "passphrase"],
        id: new Date().getTime(),
      },
      (err, result) => {
        if (err) {
          return reject(err);
        }
        return resolve(result);
      }
    );
  });
};

const send = payload => {
  if (!payload.jsonrpc) payload.jsonrpc = '2.0';
  if (!payload.id) payload.id = new Date().getTime();

  return new Promise((resolve, reject) => {
    web3.currentProvider.send(payload, (error, result) => {
      if (error) return reject(error);

      return resolve(result);
    });
  });
};

/**
 *  Mines a single block in Ganache (evm_mine is non-standard)
 */
const mineBlock = () => send({ method: 'evm_mine' });
const mineMultiBlock = (blockCnt) => send({ method: 'evm_mine', options:{blocks:blockCnt } });
/**
 *  Gets the time of the last block.
 */
const currentTime = async () => {
  const { timestamp } = await web3.eth.getBlock('latest');
  return timestamp;
};

/**
 *  Increases the time in the EVM.
 *  @param seconds Number of seconds to increase the time by
 */
const fastForward = async seconds => {
  // It's handy to be able to be able to pass big numbers in as we can just
  // query them from the contract, then send them back. If not changed to
  // a number, this causes much larger fast forwards than expected without error.
  if (BN.isBN(seconds)) seconds = seconds.toNumber();

  // And same with strings.
  if (typeof seconds === 'string') seconds = parseFloat(seconds);

  await send({
    method: 'evm_increaseTime',
    params: [seconds],
  });

  // await mineBlock();
  await mineMultiBlock(1000);
};


const getChainContracts = () => {
  let NETWORK = config.network;//process.env.NETWORK;
  console.log("network: " +NETWORK);
  var contracts = {};

  if(NETWORK == "debugZkevm" || NETWORK == "mainnetZkevm"){
    contracts = contractList.zkevm;
  }else if(NETWORK == "debug" || NETWORK == "mainnet"){
    contracts = contractList.mainnet;
  }

  return contracts;
}

const advanceTime = async (secondsElaspse) => {
  await time.increase(secondsElaspse);
  await time.advanceBlock();
  console.log("\n  >>>>  advance time " +(secondsElaspse/86400) +" days  >>>>\n");
}
const day = 86400;

contract("Deploy System and test", async accounts => {
  it("should deploy contracts and test various functions", async () => {

    
    let addressZero = "0x0000000000000000000000000000000000000000"

    let userA = accounts[0];
    let userB = accounts[1];
    let userC = accounts[2];
    let userD = accounts[3];
    let userE = accounts[4];
    let userX = "0xAdE9e51C9E23d64E538A7A38656B78aB6Bcc349e";
    let userY = "0xC8076F60cbDd2EE93D54FCc0ced88095A72f4a2f";
    let userZ = "0xAAc0aa431c237C2C0B5f041c8e59B3f1a43aC78F";
    let cvxHolder = "0x15A5F10cC2611bB18b18322E34eB473235EFCa39";
    let weth = "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2";
    var userNames = {};
    userNames[userA] = "A";
    userNames[userB] = "B";
    userNames[userC] = "C";
    userNames[userD] = "D";
    userNames[userX] = "X";
    userNames[userY] = "Y";
    userNames[userZ] = "Z";

    let deployer = "0xB4421830226F9C5Ff32060B96a3b9F8D2E0E132D";
    let feeAddress = "0x29e3b0E8dF4Ee3f71a62C34847c34E139fC0b297";
    let distributor = "0x378Ba9B73309bE80BF4C2c027aAD799766a7ED5A"
    let multisig = "0xe39b8617D571CEe5e75e1EC6B2bb40DdC8CF6Fa3";
   
    console.log("deployer: " +deployer);
    await unlockAccount(deployer);
    await unlockAccount(userX);
    await unlockAccount(cvxHolder);
    await unlockAccount(weth);

    // send 5 eth from weth to deployer and to cvxHolder to cover gas costs (weth chosen as a gaurantee of having eth on mainnet)
    await web3.eth.sendTransaction({from:weth, to:deployer, value:web3.utils.toWei("5", "ether")});
    await web3.eth.sendTransaction({from:weth, to:cvxHolder, value:web3.utils.toWei("5", "ether")});

    console.log("\n\n >>>> Begin Tests >>>>")

    //constructor(address _approved, address _approved2, address _feeAddress, address _distributor)
    var votium = await Votium.new(userY, userX, feeAddress, distributor, {from:deployer});
    console.log("votium: " +votium.address);

    var owner = await votium.owner();
    var approved1 = await votium.approvedTeam(userX);
    var approved2 = await votium.approvedTeam(userY);
    var notApproved = await votium.approvedTeam(userZ);
    var _feeAddress = await votium.feeAddress();
    var _distributor = await votium.distributor();

    console.log("owner: " +owner);
    console.log("approved1: " +approved1);
    console.log("approved2: " +approved2);
    console.log("notApproved: " +notApproved);
    console.log("feeAddress: " +_feeAddress);
    console.log("distributor: " +_distributor);

    assert(owner == multisig, "owner should be multisig");
    assert(approved1 == true, "userX should be approved");
    assert(approved2 == true, "userY should be approved");
    assert(notApproved == false, "userZ should not be approved");
    assert(_feeAddress == feeAddress, "feeAddress is wrong");
    assert(_distributor == distributor, "distributor is wrong");

    // chainContracts.system.votium = votium.address;
    // jsonfile.writeFileSync("./contracts.json", contractList, { spaces: 4 });

    console.log("\n\n --- deployed ----")
    console.log("\n\n >>> test allowlist >>>");

    // test allowlist
    var CVXaddress = "0x4e3fbd56cd56c3e72c1403e103b45db9da5b9d2b";
    var CVX = await ERC20.at(CVXaddress);
    var tokenAllowed = await votium.tokenAllowed(CVXaddress);
    console.log("tokenAllowed: " +tokenAllowed);
    assert(tokenAllowed == false, "CVX should not be allowed immediately after deployment");

    // approve CVX spending from cvxHolder to votium
    await CVX.approve(votium.address, web3.utils.toWei("1000000000", "ether"), {from:cvxHolder});
    var allowance = await CVX.allowance(cvxHolder, votium.address);
    console.log("allowance: " +allowance);
    assert(allowance == web3.utils.toWei("1000000000", "ether"), "allowance should be 1 billion");
    
    // try to depositIncentive before allowlisting
    console.log("test depositIncentive before allowlisting")
    round = await votium.activeRound();
    fail = 0;
    try{
      await votium.depositIncentive(CVXaddress, web3.utils.toWei("10000", "ether"), round, userZ, 0, {from:cvxHolder});
    }catch(e){
      fail = 1;
    }
    assert(fail == 1, "should fail to depositIncentive before allowlisting");

    // try allowToken CVX from not approved address
    console.log("test allowToken from not approved address")
    fail = 0;
    try {
      await votium.allowToken(CVXaddress, true, {from:userZ});
    }catch(e){
      fail = 1;
    }
    tokenAllowed = await votium.tokenAllowed(CVXaddress);
    console.log("tokenAllowed: " +tokenAllowed);
    assert(fail == 1, "should fail to allowToken from not approved address");
    assert(tokenAllowed == false, "CVX should not be allowed after failed allowToken");

    // allowlist CVX from approved address
    console.log("test allowToken from approved address")
    await votium.allowToken(CVXaddress, true, {from:userX});
    tokenAllowed = await votium.tokenAllowed(CVXaddress);
    console.log("tokenAllowed: " +tokenAllowed);
    assert(tokenAllowed == true, "CVX should be allowed after allowToken");

    // try to depositIncentive after allowlisting
    console.log("test depositIncentive after allowlisting")
    try {
      await votium.depositIncentive(CVXaddress, web3.utils.toWei("10000", "ether"), round, userZ, 0, {from:cvxHolder});
    }catch(e){
      console.log(e);
    }
    var balance = await CVX.balanceOf(votium.address);
    console.log("balance: " +balance);
    var fee = await votium.platformFee();
    depositMinusFee = 10000 - (10000 * fee / 10000);
    assert(balance == web3.utils.toWei(depositMinusFee.toString(), "ether"), "balance should be 10k minus fee");
    var virtualBalance = await votium.virtualBalance(CVXaddress);
    console.log("virtualBalance: " +virtualBalance);
    assert(virtualBalance == web3.utils.toWei(depositMinusFee.toString(), "ether"), "virtualBalance should be 10k minus fee");

    var gaugesLength = await votium.gaugesLength(round);
    console.log("gaugesLength: " +gaugesLength);
    assert(gaugesLength == 1, "gaugesLength should be 1");

    var gauge = await votium.roundGauges(round, 0);
    console.log("gauge: " +gauge);
    assert(gauge == userZ, "gauge should be userZ");

    var incentivesLength = await votium.incentivesLength(round, gauge);
    console.log("incentivesLength: " +incentivesLength);
    assert(incentivesLength == 1, "incentivesLength should be 1");

    var incentive = await votium.incentives(round, gauge, 0);
    console.log("incentive: ");
    console.log(" token: "+incentive.token);
    console.log(" amount: "+web3.utils.fromWei(incentive.amount, "ether"));
    console.log(" maxPerVote: "+web3.utils.fromWei(incentive.maxPerVote, "ether"));
    console.log(" distributed: "+web3.utils.fromWei(incentive.distributed, "ether"));
    console.log(" recycled: "+web3.utils.fromWei(incentive.recycled, "ether"));
    console.log(" depositor: "+incentive.depositor);

    return;
  });

});


