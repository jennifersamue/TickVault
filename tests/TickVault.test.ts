
import { beforeEach, describe, expect, it } from "vitest";
import { cvToString, standardPrincipalCV, trueCV, uintCV } from "@stacks/transactions";

const CONTRACT = "TickVault";
const BLOCKS_PER_DAY = 144;
const MIN_AMOUNT = 1_000_000;
const BONUS_RATE = 200;

const accounts = simnet.getAccounts();
const admin = accounts.get("deployer") ?? accounts.get("wallet_1")!;
const users = Array.from(accounts.values()).filter((address) => address !== admin);
if (users.length === 0) {
  users.push(admin);
}
const nonAdmin = users[0] ?? admin;

const resetSimnet = () => {
  const simnetAny = simnet as any;
  if (typeof simnetAny.reset === "function") {
    simnetAny.reset();
  }
};

const mineBlocks = (count: number) => {
  if (count <= 0) {
    return;
  }
  const simnetAny = simnet as any;
  if (typeof simnetAny.mineEmptyBlocks === "function") {
    simnetAny.mineEmptyBlocks(count);
    return;
  }
  if (typeof simnetAny.mineEmptyBlock === "function") {
    for (let i = 0; i < count; i += 1) {
      simnetAny.mineEmptyBlock();
    }
    return;
  }
  if (typeof simnetAny.mineBlocks === "function") {
    simnetAny.mineBlocks(count);
    return;
  }
  if (typeof simnetAny.mineBlock === "function") {
    for (let i = 0; i < count; i += 1) {
      simnetAny.mineBlock([]);
    }
    return;
  }
  throw new Error("Simnet mining helper not available");
};

const parseUint = (value: any) => {
  const asString = cvToString(value);
  if (!asString.startsWith("u")) {
    throw new Error(`Expected uint, got ${asString}`);
  }
  return BigInt(asString.slice(1));
};

const readUint = (fnName: string, args: any[] = []) =>
  parseUint(simnet.callReadOnlyFn(CONTRACT, fnName, args, admin).result);

const getVaultInfoString = (user: string) =>
  cvToString(
    simnet.callReadOnlyFn(
      CONTRACT,
      "get-vault-info",
      [standardPrincipalCV(user)],
      admin
    ).result
  );

const getAvailableUser = () => {
  for (const user of users) {
    if (getVaultInfoString(user).includes("none")) {
      return user;
    }
  }
  return users[0] ?? admin;
};

const getBlockHeight = () => Number(simnet.blockHeight);

const setTierReward = (duration: number, bonusRate: number) => {
  const { result } = simnet.callPublicFn(
    CONTRACT,
    "set-tier-reward",
    [uintCV(duration), uintCV(bonusRate)],
    admin
  );
  expect(result).toBeOk(trueCV());
};

const ensureBonusTier = () => {
  setTierReward(BLOCKS_PER_DAY, BONUS_RATE);
  setTierReward(BLOCKS_PER_DAY + 1, BONUS_RATE);
};

const fundTreasury = (amount: number) => {
  const { result } = simnet.callPublicFn(
    CONTRACT,
    "fund-bonus-treasury",
    [uintCV(amount)],
    admin
  );
  expect(result).toBeOk(uintCV(amount));
};

const getEmergencyMode = () =>
  cvToString(simnet.callReadOnlyFn(CONTRACT, "get-emergency-mode", [], admin).result) ===
  "true";

const setEmergencyMode = (enabled: boolean) => {
  if (getEmergencyMode() === enabled) {
    return;
  }
  const { result } = simnet.callPublicFn(CONTRACT, "toggle-emergency-mode", [], admin);
  expect(result).toBeOk(trueCV());
};

beforeEach(() => {
  resetSimnet();
});

describe("TickVault core flows", () => {
  it("ensures simnet is well initialised", () => {
    expect(simnet.blockHeight).toBeDefined();
  });

  it("locks STX with bonus and updates totals", () => {
    const user = getAvailableUser();
    const amount = MIN_AMOUNT;
    const bonusAmount = amount;
    const totalAmount = amount + bonusAmount;
    const fundAmount = amount * 5;

    const startLocked = readUint("get-total-locked-stx");
    const startObligations = readUint("get-total-bonus-obligations");
    const startTreasury = readUint("get-bonus-treasury");

    ensureBonusTier();
    fundTreasury(fundAmount);
    const unlockHeight = getBlockHeight() + BLOCKS_PER_DAY + 1;

    const { result } = simnet.callPublicFn(
      CONTRACT,
      "lock-funds",
      [uintCV(amount), uintCV(unlockHeight)],
      user
    );
    expect(result).toBeOk(trueCV());

    expect(readUint("get-total-locked-stx")).toBe(startLocked + BigInt(amount));
    expect(readUint("get-total-bonus-obligations")).toBe(
      startObligations + BigInt(bonusAmount)
    );
    expect(readUint("get-bonus-treasury")).toBe(startTreasury + BigInt(fundAmount));

    const vaultInfo = getVaultInfoString(user);
    expect(vaultInfo).toContain("some");
    expect(vaultInfo).toContain(`amount u${totalAmount}`);
    expect(vaultInfo).toContain(`original-amount u${amount}`);
  });

  it("rejects locks with invalid amount", () => {
    const user = getAvailableUser();
    const unlockHeight = getBlockHeight() + BLOCKS_PER_DAY + 1;

    const { result } = simnet.callPublicFn(
      CONTRACT,
      "lock-funds",
      [uintCV(MIN_AMOUNT - 1), uintCV(unlockHeight)],
      user
    );

    expect(result).toBeErr(uintCV(101));
  });

  it("prevents withdraw before unlock", () => {
    const user = getAvailableUser();
    const amount = MIN_AMOUNT;
    const fundAmount = amount * 3;

    ensureBonusTier();
    fundTreasury(fundAmount);
    const unlockHeight = getBlockHeight() + BLOCKS_PER_DAY + 1;

    const lockResult = simnet.callPublicFn(
      CONTRACT,
      "lock-funds",
      [uintCV(amount), uintCV(unlockHeight)],
      user
    );
    expect(lockResult.result).toBeOk(trueCV());

    const { result } = simnet.callPublicFn(CONTRACT, "withdraw", [], user);
    expect(result).toBeErr(uintCV(104));
  });

  it("withdraws after unlock and clears vault", () => {
    const user = getAvailableUser();
    const amount = MIN_AMOUNT;
    const bonusAmount = amount;
    const totalAmount = amount + bonusAmount;
    const fundAmount = amount * 3;

    const startLocked = readUint("get-total-locked-stx");
    const startObligations = readUint("get-total-bonus-obligations");
    const startTreasury = readUint("get-bonus-treasury");

    ensureBonusTier();
    fundTreasury(fundAmount);
    const unlockHeight = getBlockHeight() + BLOCKS_PER_DAY + 1;

    const lockResult = simnet.callPublicFn(
      CONTRACT,
      "lock-funds",
      [uintCV(amount), uintCV(unlockHeight)],
      user
    );
    expect(lockResult.result).toBeOk(trueCV());

    const blocksToMine = unlockHeight - getBlockHeight();
    mineBlocks(blocksToMine);

    const { result } = simnet.callPublicFn(CONTRACT, "withdraw", [], user);
    expect(result).toBeOk(uintCV(totalAmount));

    expect(readUint("get-total-locked-stx")).toBe(startLocked);
    expect(readUint("get-total-bonus-obligations")).toBe(startObligations);
    expect(readUint("get-bonus-treasury")).toBe(
      startTreasury + BigInt(fundAmount - bonusAmount)
    );

    const vaultInfo = getVaultInfoString(user);
    expect(vaultInfo).toContain("none");
  });

  it("partial withdraw reduces obligations proportionally", () => {
    const user = getAvailableUser();
    const amount = MIN_AMOUNT;
    const bonusAmount = amount;
    const totalAmount = amount + bonusAmount;
    const withdrawAmount = 400_000;
    const fundAmount = amount * 3;

    ensureBonusTier();
    fundTreasury(fundAmount);
    const unlockHeight = getBlockHeight() + BLOCKS_PER_DAY + 1;

    const lockResult = simnet.callPublicFn(
      CONTRACT,
      "lock-funds",
      [uintCV(amount), uintCV(unlockHeight)],
      user
    );
    expect(lockResult.result).toBeOk(trueCV());

    const blocksToMine = unlockHeight - getBlockHeight();
    mineBlocks(blocksToMine);

    const lockedAfterLock = readUint("get-total-locked-stx");
    const obligationsAfterLock = readUint("get-total-bonus-obligations");
    const treasuryAfterLock = readUint("get-bonus-treasury");
    const bonusPortion =
      (BigInt(bonusAmount) * BigInt(withdrawAmount)) / BigInt(totalAmount);

    const { result } = simnet.callPublicFn(
      CONTRACT,
      "partial-withdraw",
      [uintCV(withdrawAmount)],
      user
    );
    expect(result).toBeOk(uintCV(withdrawAmount));

    expect(readUint("get-total-locked-stx")).toBe(lockedAfterLock);
    expect(readUint("get-total-bonus-obligations")).toBe(
      obligationsAfterLock - bonusPortion
    );
    expect(readUint("get-bonus-treasury")).toBe(treasuryAfterLock - bonusPortion);

    const vaultInfo = getVaultInfoString(user);
    expect(vaultInfo).toContain(`amount u${totalAmount - withdrawAmount}`);
  });

  it("enforces admin-only controls and emergency mode requirement", () => {
    const pauseResult = simnet.callPublicFn(CONTRACT, "pause-contract", [], nonAdmin);
    expect(pauseResult.result).toBeErr(uintCV(100));

    const pauseOk = simnet.callPublicFn(CONTRACT, "pause-contract", [], admin);
    expect(pauseOk.result).toBeOk(trueCV());

    const unpauseOk = simnet.callPublicFn(CONTRACT, "unpause-contract", [], admin);
    expect(unpauseOk.result).toBeOk(trueCV());

    setEmergencyMode(false);
    const emergencyResult = simnet.callPublicFn(
      CONTRACT,
      "emergency-withdraw",
      [standardPrincipalCV(nonAdmin)],
      admin
    );
    expect(emergencyResult.result).toBeErr(uintCV(106));
  });

  it("allows emergency withdraw when enabled", () => {
    const user = getAvailableUser();
    const amount = MIN_AMOUNT;
    const bonusAmount = amount;
    const totalAmount = amount + bonusAmount;
    const fundAmount = amount * 3;

    ensureBonusTier();
    fundTreasury(fundAmount);
    const unlockHeight = getBlockHeight() + BLOCKS_PER_DAY + 1;

    const lockResult = simnet.callPublicFn(
      CONTRACT,
      "lock-funds",
      [uintCV(amount), uintCV(unlockHeight)],
      user
    );
    expect(lockResult.result).toBeOk(trueCV());

    setEmergencyMode(true);

    const { result } = simnet.callPublicFn(
      CONTRACT,
      "emergency-withdraw",
      [standardPrincipalCV(user)],
      admin
    );
    expect(result).toBeOk(uintCV(totalAmount));

    const vaultInfo = getVaultInfoString(user);
    expect(vaultInfo).toContain("none");

    setEmergencyMode(false);
  });
});
