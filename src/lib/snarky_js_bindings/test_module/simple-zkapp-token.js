import {
  Field,
  declareState,
  declareMethods,
  State,
  PrivateKey,
  SmartContract,
  isReady,
  shutdown,
  Mina,
  Permissions,
  Ledger,
  Party,
  UInt64,
  Bool,
  partiesToJson,
} from "snarkyjs";

function sendTransaction(tx) {
  console.log("DEBUG -- TXN", JSON.stringify(partiesToJson(tx.transaction)));
  tx.send();
}

await isReady;

// declare the zkapp
class SimpleZkapp extends SmartContract {
  constructor(address) {
    super(address);
    this.x = State();
  }

  deploy(args) {
    super.deploy(args);
    this.setPermissions({
      ...Permissions.default(),
      editState: Permissions.proofOrSignature(),
    });
    this.balance.addInPlace(UInt64.fromNumber(initialBalance));
    this.x.set(initialState);
  }

  update(y) {
    let x = this.x.get();
    this.x.set(x.add(y));
  }

  initialize() {
    this.x.set(initialState);
  }

  payout(caller) {
    // check that caller is the privileged account
    let callerAddress = caller.toPublicKey();
    callerAddress.assertEquals(privilegedAddress);

    // assert that the caller nonce is 0, and increment the nonce - this way, payout can only happen once
    let callerParty = Party.createUnsigned(callerAddress);
    // callerParty.account.nonce.assertEquals(UInt32.zero);
    callerParty.body.incrementNonce = Bool(true);

    // pay out half of the zkapp balance to the caller
    let balance = this.account.balance.get();
    this.account.balance.assertEquals(balance);

    let halfBalance = balance.div(2);
    this.transfer(halfBalance, callerParty);
  }

  sendTokenWithAccountCreation(receiver) {
    let recieverAddress = receiver.toPublicKey();
    recieverAddress.assertEquals(privilegedAddress);

    // transfer custom tokens to the receiver
    let balance = this.account.balance.get();
    this.account.balance.assertEquals(balance);
    let amountToSend = balance.div(10);

    // Log custom token info
    const customToken = Ledger.customTokenID(this.address);
    console.log("TOKEN OWNER", this.address.toBase58());
    console.log("TOKEN ACCOUNT", recieverAddress.toBase58());
    console.log("CUSTOM TOKEN", customToken);

    this.token.transfer({
      from: this.address,
      to: recieverAddress,
      amount: amountToSend,
      accountCreation: true,
    });

    console.log(`Sending ${amountToSend} to ${recieverAddress.toBase58()}`);
  }

  sendTokenWithoutAccountCreation(receiver) {
    let recieverAddress = receiver.toPublicKey();
    recieverAddress.assertEquals(privilegedAddress);

    // transfer custom tokens to the receiver
    let balance = this.account.balance.get();
    this.account.balance.assertEquals(balance);
    let amountToSend = balance.div(10);

    this.token.transfer({
      from: this.address,
      to: recieverAddress,
      amount: amountToSend,
    });

    console.log(`Sending ${amountToSend} to ${recieverAddress.toBase58()}`);
  }
}
// note: this is our non-typescript way of doing what our decorators do
declareState(SimpleZkapp, { x: Field });
declareMethods(SimpleZkapp, {
  initialize: [],
  update: [Field],
  payout: [PrivateKey],
  sendTokenWithAccountCreation: [PrivateKey],
  sendTokenWithoutAccountCreation: [PrivateKey],
});

let Local = Mina.LocalBlockchain();
Mina.setActiveInstance(Local);

// a test account that pays all the fees, and puts additional funds into the zkapp
let feePayer = Local.testAccounts[0].privateKey;

// the zkapp account
let zkappKey = PrivateKey.fromBase58(
  "EKEfEZpMctKoyon4nxhqFBiKyUsCyyZReF9fbs21nDrrTgGMTcok"
);
let zkappAddress = zkappKey.toPublicKey();

// a special account that is allowed to pull out half of the zkapp balance, once
let privilegedKey = Local.testAccounts[1].privateKey;
let privilegedAddress = privilegedKey.toPublicKey();

let initialBalance = 10_000_000_000;
let initialState = Field(1);
let zkapp = new SimpleZkapp(zkappAddress);

console.log("deploy");
let tx = await Local.transaction(feePayer, () => {
  Party.fundNewAccount(feePayer, { initialBalance });
  zkapp.deploy({ zkappKey });
});
tx.send();

console.log("initial state: " + zkapp.x.get());
console.log(`initial balance: ${zkapp.account.balance.get().div(1e9)} MINA`);

// console.log("payout");
// tx = await Local.transaction(feePayer, () => {
//   zkapp.payout(privilegedKey);
//   zkapp.sign(zkappKey);
// });
// sendTransaction(tx);

// console.log("payout2");
// tx = await Local.transaction(feePayer, () => {
//   zkapp.payout(privilegedKey);
//   zkapp.sign(zkappKey);
// });
// sendTransaction(tx);

console.log("token transfer with account creation");
tx = await Local.transaction(feePayer, () => {
  zkapp.sendTokenWithAccountCreation(privilegedKey);
  zkapp.sign(zkappKey);
});

sendTransaction(tx);

console.log("token transfer without account creation");
tx = await Local.transaction(feePayer, () => {
  zkapp.sendTokenWithoutAccountCreation(privilegedKey);
  zkapp.sign(zkappKey);
});

sendTransaction(tx);

shutdown();
