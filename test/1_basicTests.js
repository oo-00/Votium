// const { BN, constants, expectEvent, expectRevert, time } = require('openzeppelin-test-helpers');
const { BN, time } = require('openzeppelin-test-helpers');
var jsonfile = require('jsonfile');
const { assert } = require('chai');
const { web3 } = require('openzeppelin-test-helpers/src/setup');

const verbose = false;

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
        params: [address, "passphrase",15000],
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

async function tryCatch(promise, expected) {
  try {
    await promise;
    return false;
  }
  catch (e) {
    return true;
  }
}

function verboseLog(msg) {
  if (verbose) {
    console.log(msg);
  }
}


const addressZero = "0x0000000000000000000000000000000000000000"

var userA;
var userB;
var userC;
var userD;
var userE;
var userF;
var userG;
var userH;
var userI;
var userJ;

var userX = "0xAdE9e51C9E23d64E538A7A38656B78aB6Bcc349e";
var userY = "0xC8076F60cbDd2EE93D54FCc0ced88095A72f4a2f";
var userZ = "0xAAc0aa431c237C2C0B5f041c8e59B3f1a43aC78F";
var cvxHolder = "0x15A5F10cC2611bB18b18322E34eB473235EFCa39";
var weth = "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2";
var userNames = {};
userNames[userA] = "A";
userNames[userB] = "B";
userNames[userC] = "C";
userNames[userD] = "D";
userNames[userX] = "X";
userNames[userY] = "Y";
userNames[userZ] = "Z";

var deployer = "0xB4421830226F9C5Ff32060B96a3b9F8D2E0E132D";
var feeAddress = "0x29e3b0E8dF4Ee3f71a62C34847c34E139fC0b297";
var distributor = "0x378Ba9B73309bE80BF4C2c027aAD799766a7ED5A"
var multisig = "0xe39b8617D571CEe5e75e1EC6B2bb40DdC8CF6Fa3";

var maxRounds = 7;

var votium;

var round;
var fee;
var expectedIncentivesLength = {};
var expectedGaugesLength = {};
var inRoundGauges = {};
var owner;
var approved1;
var approved2;
var notApproved;
var _feeAddress;
var _distributor;

var CVXaddress = "0x4e3fbd56cd56c3e72c1403e103b45db9da5b9d2b";
var CVX;
var tokenAllowed;

var depositMinusFee = 0;
var vdepositMinusFee = new BN(0);
var gaugeArr;

async function testDepositIncentive(max) {
    verboseLog("test depositIncentive with rounds in acceptable range, maxPerVote: " +max)
    for(var i=0; i<maxRounds; i++){
      verboseLog(" depositIncentive round: " +(round+i));
      await votium.depositIncentive(CVXaddress, web3.utils.toWei("10000", "ether"), round+i, userZ, max, {from:cvxHolder});
      if(expectedIncentivesLength[userZ][round+i] == undefined) { expectedIncentivesLength[userZ][round+i] = 0; }
      expectedIncentivesLength[userZ][round+i]++;
      if(expectedGaugesLength[round+i] == undefined) { expectedGaugesLength[round+i] = 0; }
      if(inRoundGauges[round+i] == undefined) { inRoundGauges[round+i] = {}; }
      if(inRoundGauges[round+i][userZ] == undefined) { 
        inRoundGauges[round+i][userZ] = 1; 
        expectedGaugesLength[round+i]++;
      }
      depositMinusFee += 10000 - (10000 * fee / 10000);
      vdepositMinusFee = vdepositMinusFee.add(new BN(web3.utils.toWei("10000")).sub(new BN(web3.utils.toWei("10000")).mul(new BN(fee)).div(new BN(10000))));
      var balance = await CVX.balanceOf(votium.address);
      verboseLog("   balance: " +balance);
      assert(balance == web3.utils.toWei(depositMinusFee.toString(), "ether"), "balance should be "+depositMinusFee);
      var virtualBalance = await votium.virtualBalance(CVXaddress);
      verboseLog("   virtualBalance: " +virtualBalance);
      assert(virtualBalance == vdepositMinusFee.toString(), "virtualBalance should be "+vdepositMinusFee.toString());
  
      var gaugesLength = await votium.gaugesLength(round+i);
      verboseLog("   gaugesLength: " +gaugesLength);
      assert(gaugesLength == expectedGaugesLength[round+i], "round "+(round+i)+" gaugesLength should be 1");
  
      var gauge = await votium.roundGauges(round+i, 0);
      verboseLog("   gauge: " +gauge);
      assert(gauge == userZ, "round "+(round+i)+" gauge 0 should be userZ");
  
      var incentivesLength = await votium.incentivesLength(round+i, gauge);
      verboseLog("   incentivesLength: " +incentivesLength);
      assert(incentivesLength == expectedIncentivesLength[userZ][round+i], "round "+(round+i)+" gauge "+userZ+" incentivesLength should be "+expectedIncentivesLength[userZ][round+i]);
  
      var incentive = await votium.incentives(round+i, gauge, Number(incentivesLength)-1);
      verboseLog("   incentive: ");
      verboseLog("     token: "+incentive.token);
      verboseLog("     amount: "+incentive.amount.toString());
      verboseLog("     maxPerVote: "+incentive.maxPerVote.toString());
      verboseLog("     distributed: "+incentive.distributed.toString());
      verboseLog("     recycled: "+incentive.recycled.toString());
      verboseLog("     depositor: "+incentive.depositor);
    }
    
}

async function testSplitRounds(max) {
  verboseLog("test depositSplitRounds with "+maxRounds+" rounds, maxPerVote "+max)
  for(var i=2; i<=maxRounds; i++) {
    if(i == 3) { i = maxRounds; } // only test depositing for min and max rounds
    verboseLog(" depositSplitRounds rounds: " +i)
    await votium.depositSplitRounds(CVXaddress, web3.utils.toWei("10000", "ether"), i, userA, max, {from:cvxHolder});
    for(var r=0;r<i;r++) {
      if(expectedIncentivesLength[userA][round+r] == undefined) { expectedIncentivesLength[userA][round+r] = 0; }
      expectedIncentivesLength[userA][round+r]++;
      if(expectedGaugesLength[round+r] == undefined) { expectedGaugesLength[round+r] = 0; }
      if(inRoundGauges[round+r] == undefined) { inRoundGauges[round+r] = {}; }
      if(inRoundGauges[round+r][userA] == undefined) {
        inRoundGauges[round+r][userA] = 1;
        expectedGaugesLength[round+r]++;
      }
    }
    var balance = await CVX.balanceOf(votium.address);
    verboseLog("   balance: " +balance);
    vdepositMinusFee = vdepositMinusFee.add(new BN(new BN(new BN(web3.utils.toWei("10000")).sub(new BN(web3.utils.toWei("10000")).mul(new BN(fee)).div(new BN(10000)))).div(new BN(i))).mul(new BN(i)));
    depositMinusFee += 10000 - (10000 * fee / 10000);
    assert(balance == web3.utils.toWei(depositMinusFee.toString(), "ether"), "balance should be "+depositMinusFee.toString());
    var virtualBalance = await votium.virtualBalance(CVXaddress);
    verboseLog("   virtualBalance: " +virtualBalance);
    assert(virtualBalance == vdepositMinusFee.toString(), "virtualBalance should be "+vdepositMinusFee.toString());

    for(var n=0; n<i; n++) {
      verboseLog("   round "+(round+n));
      var gaugesLength = await votium.gaugesLength(round+n);
      verboseLog("     gaugesLength: " +gaugesLength);
      assert(gaugesLength == expectedGaugesLength[round+n], "round "+(round+n)+" gaugesLength should be "+expectedGaugesLength[round+n]);
  
      var gauge = await votium.roundGauges(round+n, 1);
      verboseLog("     gauge: " +gauge);
      assert(gauge == userA, "round "+(round+n)+" gauge 1 should be userA");
  
      var incentivesLength = await votium.incentivesLength(round+n, gauge);
      verboseLog("     incentivesLength: " +incentivesLength);

      assert(incentivesLength == expectedIncentivesLength[userA][round+n], "round "+(round+n)+" gauge "+userA+" incentivesLength should be "+expectedIncentivesLength[userA][round+n]);
  
      var incentive = await votium.incentives(round+n, gauge, Number(incentivesLength)-1);
      verboseLog("     incentive: ");
      verboseLog("       token: "+incentive.token);
      verboseLog("       amount: "+incentive.amount.toString());
      verboseLog("       maxPerVote: "+incentive.maxPerVote.toString());
      verboseLog("       distributed: "+incentive.distributed.toString());
      verboseLog("       recycled: "+incentive.recycled.toString());
      verboseLog("       depositor: "+incentive.depositor);
      bnamount = new BN(web3.utils.toWei((10000 - (10000 * fee / 10000)).toString(), "ether"));
      bnamount = bnamount.div(new BN(i));
      verboseLog("      amount should be "+bnamount.toString());
      assert(incentive.amount.toString() == bnamount.toString(), "incentive amount should be "+bnamount.toString());
    }
  }
}

async function testSplitGauges(gauges, amount, max) {
  verboseLog("test depositSplitGauges with "+gauges.length+" gauges, in acceptable round range, maxPerVote "+max);
  for(var i=0; i<maxRounds; i++) {
    if(i == 1) { i = maxRounds-1; } // only test current and last round
    verboseLog(" depositSplitGauges round: " +(round+i))
    /*
        address _token,
        uint256 _amount,
        uint256 _round,
        address[] calldata _gauges,
        uint256 _maxPerVote
    */
    await votium.depositSplitGauges(CVXaddress, web3.utils.toWei(amount, "ether"), round+i, gauges, max, {from:cvxHolder});
    for(var n=0;n<gauges.length;n++) {
      if(expectedIncentivesLength[gauges[n]] == undefined) { expectedIncentivesLength[gauges[n]] = {}; }
      if(expectedIncentivesLength[gauges[n]][round+i] == undefined) { expectedIncentivesLength[gauges[n]][round+i] = 0; }
      expectedIncentivesLength[gauges[n]][round+i]++;
      if(expectedGaugesLength[round+i] == undefined) { expectedGaugesLength[round+i] = 0; }
      if(inRoundGauges[round+i] == undefined) { inRoundGauges[round+i] = {}; }
      if(inRoundGauges[round+i][gauges[n]] == undefined) {
        inRoundGauges[round+i][gauges[n]] = 1;
        expectedGaugesLength[round+i]++;
      }
    }
    var balance = await CVX.balanceOf(votium.address);
    verboseLog("   balance: " +balance);
    vdepositMinusFee = vdepositMinusFee.add(new BN(new BN(new BN(web3.utils.toWei(amount)).sub(new BN(web3.utils.toWei(amount)).mul(new BN(fee)).div(new BN(10000)))).div(new BN(gauges.length))).mul(new BN(gauges.length)));
    depositMinusFee += Number(amount) - (Number(amount) * fee / 10000);
    assert(balance == web3.utils.toWei(depositMinusFee.toString(), "ether"), "balance should be "+depositMinusFee.toString());
    var virtualBalance = await votium.virtualBalance(CVXaddress);
    verboseLog("   virtualBalance: " +virtualBalance);
    assert(virtualBalance == vdepositMinusFee.toString(), "virtualBalance should be "+vdepositMinusFee.toString());

    var gaugesLength = await votium.gaugesLength(round+i);
    verboseLog("     gaugesLength: " +gaugesLength);
    assert(gaugesLength == expectedGaugesLength[round+i], "round "+(round+i)+" gaugesLength should be "+expectedGaugesLength[round+i]);

    bnamount = new BN(web3.utils.toWei((Number(amount) - (Number(amount) * fee / 10000)).toString(), "ether"));
    bnamount = bnamount.div(new BN(gauges.length));

    for(var n=0; n<gauges.length; n++) {
      var gauge = await votium.roundGauges(round+i, expectedGaugesLength[round+i]-gauges.length+n);
      verboseLog("     gauge: " +gauge);
      assert(gauge == gauges[n], "round "+(round+i)+" gauge "+(expectedGaugesLength[round+i]-gauges.length+n)+" should be "+gauges[n]);
  
      var incentivesLength = await votium.incentivesLength(round+i, gauge);
      verboseLog("     incentivesLength: " +incentivesLength);

      assert(incentivesLength == expectedIncentivesLength[gauges[n]][round+i], "round "+(round+i)+" gauge "+gauges[n]+" incentivesLength should be "+expectedIncentivesLength[gauges[n]][round+n]);
  
      var incentive = await votium.incentives(round+i, gauge, Number(incentivesLength)-1);
      verboseLog("     incentive: ");
      verboseLog("       token: "+incentive.token);
      verboseLog("       amount: "+incentive.amount.toString());
      verboseLog("       maxPerVote: "+incentive.maxPerVote.toString());
      verboseLog("       distributed: "+incentive.distributed.toString());
      verboseLog("       recycled: "+incentive.recycled.toString());
      verboseLog("       depositor: "+incentive.depositor);

      verboseLog("      amount should be "+bnamount.toString());
      assert(incentive.amount.toString() == bnamount.toString(), "incentive amount should be "+bnamount.toString());
    }
  }
}


contract("Deploy System and test", async accounts => {
    it("should deploy system", async () => {

      userA = accounts[0];
      userB = accounts[1];
      userC = accounts[2];
      userD = accounts[3];
      userE = accounts[4];
      userF = accounts[5];
      userG = accounts[6];
      userH = accounts[7];
      userI = accounts[8];
      userJ = accounts[9];


      expectedIncentivesLength[userZ] = {};
      expectedIncentivesLength[userA] = {};
    
      verboseLog("deployer: " +deployer);
      await unlockAccount(deployer);
      await unlockAccount(userX);
      await unlockAccount(cvxHolder);
      await unlockAccount(weth);

      // send 5 eth from weth to deployer and to cvxHolder to cover gas costs (weth chosen as a gaurantee of having eth on mainnet)
      await web3.eth.sendTransaction({from:weth, to:deployer, value:web3.utils.toWei("5", "ether")});
      await web3.eth.sendTransaction({from:weth, to:cvxHolder, value:web3.utils.toWei("5", "ether")});

      //constructor(address _approved, address _approved2, address _feeAddress, address _distributor)
      votium = await Votium.new(userY, userX, feeAddress, distributor, {from:deployer});
      verboseLog("votium: " +votium.address);
      assert(votium.address != addressZero, "votium address is zero");

      owner = await votium.owner();
      approved1 = await votium.approvedTeam(userX);
      approved2 = await votium.approvedTeam(userY);
      notApproved = await votium.approvedTeam(userZ);
      _feeAddress = await votium.feeAddress();
      _distributor = await votium.distributor();
      round = await votium.activeRound();
      fee = await votium.platformFee();
      tokenAllowed = await votium.tokenAllowed(CVXaddress);


      round = Number(round)
      fee = Number(fee)

      verboseLog("owner: " +owner);
      verboseLog("approved1: " +approved1);
      verboseLog("approved2: " +approved2);
      verboseLog("notApproved: " +notApproved);
      verboseLog("feeAddress: " +_feeAddress);
      verboseLog("distributor: " +_distributor);
      verboseLog("\nround: " +round);
      verboseLog("fee: " +fee);
    });

    it("should have correct initial values", async () => {
      assert(owner == multisig, "owner should be multisig");
      assert(approved1 == true, "userX should be approved");
      assert(approved2 == true, "userY should be approved");
      assert(notApproved == false, "userZ should not be approved");
      assert(_feeAddress == feeAddress, "feeAddress is wrong");
      assert(_distributor == distributor, "distributor is wrong");
      assert(tokenAllowed == false, "token allowed after deployment");
    });

    // chainContracts.system.votium = votium.address;
    // jsonfile.writeFileSync("./contracts.json", contractList, { spaces: 4 });


    //!!!!!!!!!!!!!!!!!!!!!! ALLOW LIST TESTS !!!!!!!!!!!!!!!!!!

    it("cvxHolder approve spending", async () => {
      CVX = await ERC20.at(CVXaddress);
      // approve CVX spending from cvxHolder to votium
      verboseLog("approve CVX spending from cvxHolder to votium")
      await CVX.approve(votium.address, web3.utils.toWei("1000000000", "ether"), {from:cvxHolder});
      var allowance = await CVX.allowance(cvxHolder, votium.address);
      verboseLog(" allowance: " +allowance);
      assert(allowance == web3.utils.toWei("1000000000", "ether"), "allowance should be 1 billion");
    });
    
    it("should not allow deposits before allowlisting", async () => {
      // try to depositIncentive before allowlisting
      verboseLog("test depositIncentive before allowlisting")
      fail = await tryCatch(votium.depositIncentive(CVXaddress, web3.utils.toWei("10000", "ether"), round, userZ, 0, {from:cvxHolder}));
      assert(fail, "should fail to depositIncentive before allowlisting");
      verboseLog(" depositIncentive failed as expected");
      verboseLog("test depositSplitRounds before allowlisting")
      fail = await tryCatch(votium.depositSplitRounds(CVXaddress, web3.utils.toWei("10000", "ether"), 2, userZ, 0, {from:cvxHolder}));
      assert(fail, "should fail to depositSplitRounds before allowlisting");
      verboseLog(" depositSplitRounds failed as expected");
      verboseLog("test depositSplitGauges before allowlisting")
      fail = await tryCatch(votium.depositSplitGauges(CVXaddress, web3.utils.toWei("10000", "ether"), round, [userZ,weth], 0, {from:cvxHolder}));
      assert(fail, "should fail to depositSplitGauges before allowlisting");
      verboseLog(" depositSplitGauges failed as expected");
      verboseLog("test depositSplitGaugesRounds before allowlisting")
      fail = await tryCatch(votium.depositSplitGaugesRounds(CVXaddress, web3.utils.toWei("10000", "ether"), 2, [userZ,weth], 0, {from:cvxHolder}));
      assert(fail, "should fail to depositSplitGaugesRounds before allowlisting");
      verboseLog(" depositSplitGaugesRounds failed as expected");
      verboseLog("test depositUnevenSplitGauges before allowlisting");
      fail = await tryCatch(votium.depositUnevenSplitGauges(CVXaddress, round, [userA,userB], [web3.utils.toWei("3000", "ether"),web3.utils.toWei("4000", "ether")], 0, {from:cvxHolder}));
      assert(fail, "should fail to depositUnevenSplitGauges before allowlisting");
      verboseLog(" depositUnevenSplitGauges failed as expected");
    });
    // try allowToken CVX from not approved address
    it("should not allow `allowToken` from not approved address", async () => {
      verboseLog("test allowToken true from not approved address")
      fail = await tryCatch(votium.allowToken(CVXaddress, true, {from:userZ}));
      assert(fail, "should fail to allowToken from not approved address");
      verboseLog(" allowToken failed as expected")
    });

    // allowlist CVX from approved address
    it("should allow `allowToken` from approved address", async () => {
      verboseLog("test allowToken true from approved address")
      await votium.allowToken(CVXaddress, true, {from:userX});
      tokenAllowed = await votium.tokenAllowed(CVXaddress);
      verboseLog(" tokenAllowed: " +tokenAllowed);
      assert(tokenAllowed == true, "CVX should be allowed after allowToken");
    });

    //!!!!!!!!!!!!!!!!!!!!!! DEPOSITINCENTIVE TESTS !!!!!!!!!!!!!!!!!!

    
    it("should not allow depositIncentive outside of round range", async () => {
      verboseLog("test depositIncentive with a round too far into the future")
      fail = await tryCatch(votium.depositIncentive(CVXaddress, web3.utils.toWei("10000", "ether"), round+maxRounds, userZ, 0, {from:cvxHolder}));
      assert(fail, "should fail to depositIncentive with a round too far into the future");
      verboseLog(" depositIncentive failed as expected");
      verboseLog("test depositIncentive with a round in the past")
      fail = await tryCatch(votium.depositIncentive(CVXaddress, web3.utils.toWei("10000", "ether"), round-1, userZ, 0, {from:cvxHolder}));
      assert(fail, "should fail to depositIncentive with a round in the past");
      verboseLog(" depositIncentive failed as expected");
    });

    it("should allow depositIncentive with rounds in acceptable range, maxPerVote: 0", async () => {
      await testDepositIncentive(0);
    });
    it("should allow depositIncentive with rounds in acceptable range, maxPerVote: .001", async () => {
      await testDepositIncentive(web3.utils.toWei(".001", "ether"));
    });
    //!!!!!!!!!!!!!!!!!!!!!! DEPOSITSPLITROUNDS TESTS !!!!!!!!!!!!!!!!!!

    it("should not allow depositSplitRounds outside of round range", async () => {
      fail = await tryCatch(votium.depositSplitRounds(CVXaddress, web3.utils.toWei("10000", "ether"), maxRounds+1, userA, 0, {from:cvxHolder}));
      assert(fail, "should fail to depositSplitRounds with "+(maxRounds+1)+" rounds");
      verboseLog(" depositSplitRounds failed as expected");
      verboseLog("test depositSplitRounds with 0 rounds");
      fail = await tryCatch(votium.depositSplitRounds(CVXaddress, web3.utils.toWei("10000", "ether"), 0, userA, 0, {from:cvxHolder}));
      assert(fail, "should fail to depositSplitRounds with 0 rounds");
      verboseLog(" depositSplitRounds failed as expected");
      verboseLog("test depositSplitRounds with 1 round");
      fail = await tryCatch(votium.depositSplitRounds(CVXaddress, web3.utils.toWei("10000", "ether"), 1, userA, 0, {from:cvxHolder}));
      assert(fail, "should fail to depositSplitRounds with 1 round");
      verboseLog(" depositSplitRounds failed as expected");
    });

    it("should allow depositSplitRounds with rounds in acceptable range, maxPerVote: 0", async () => {
      await testSplitRounds(0);
    });
    it("should allow depositSplitRounds with rounds in acceptable range, maxPerVote: .0015", async () => {
      await testSplitRounds(web3.utils.toWei(".0015", "ether"));
    });

    //!!!!!!!!!!!!!!!!!!!!!! DEPOSITSPLITGAUGES TESTS !!!!!!!!!!!!!!!!!!

    it("should not allow depositSplitGauges outside of gauge/round range", async () => {
      gaugeArr = [userC,userD,userE,userF,userG,userH,userI];

      fail = await tryCatch(votium.depositSplitGauges(CVXaddress, web3.utils.toWei("100", "ether"), round+maxRounds, gaugeArr, 0, {from:cvxHolder}));
      assert(fail, "should fail to depositSplitGauges with for round "+(round+maxRounds));
      verboseLog(" depositSplitGauges failed as expected");
      fail = await tryCatch(votium.depositSplitGauges(CVXaddress, web3.utils.toWei("100", "ether"), round-1, gaugeArr, 0, {from:cvxHolder}));
      assert(fail, "should fail to depositSplitGauges with for round "+(round-1));
      verboseLog(" depositSplitGauges failed as expected");
      verboseLog("test depositSplitGauges with 0 or 1 gauges");
      fail = await tryCatch(votium.depositSplitGauges(CVXaddress, web3.utils.toWei("100", "ether"), round+maxRounds, [], 0, {from:cvxHolder}));
      assert(fail, "should fail to depositSplitGauges with 0 gauges");
      fail = await tryCatch(votium.depositSplitGauges(CVXaddress, web3.utils.toWei("100", "ether"), round+maxRounds, [userA], 0, {from:cvxHolder}));
      assert(fail, "should fail to depositSplitGauges with 1 gauge");
      verboseLog(" depositSplitGauges failed as expected");
    });

    it("should allow depositSplitGauges with rounds and gauges in acceptable range, maxPerVote: 0", async () => {
      await testSplitGauges(gaugeArr, "500", 0);
    });
    it("should allow depositSplitRounds with rounds in acceptable range, maxPerVote: .001233333333333333", async () => {
      await testSplitGauges(gaugeArr, "500", "1233333333333333");
    });

    return;
});


