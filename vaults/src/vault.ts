import { BigInt, Bytes } from "@graphprotocol/graph-ts"
import {
  SetupCompleted,
  TimelockUpdated,
  ProvidersUpdated,
  ActiveProviderUpdated,
  TreasuryUpdated,
  WithdrawFeePercentUpdated,
  MinAmountUpdated,
  FeeCharged,
  RebalanceExecuted,
  RewardsTransferred,
  DistributorUpdated,
} from "../generated/Vault/Vault"
import { 
  Vault, 
  Provider, 
  Rebalance,
  Fee,
  SetupCompleted as SetupCompletedEntity,
  TimelockUpdated as TimelockUpdatedEntity,
  ProvidersUpdated as ProvidersUpdatedEntity,
  ActiveProviderUpdated as ActiveProviderUpdatedEntity,
  TreasuryUpdated as TreasuryUpdatedEntity,
  WithdrawFeePercentUpdated as WithdrawFeePercentUpdatedEntity,
  MinAmountUpdated as MinAmountUpdatedEntity,
  FeeCharged as FeeChargedEntity,
  RebalanceExecuted as RebalanceExecutedEntity,
  RewardsTransferred as RewardsTransferredEntity,
  DistributorUpdated as DistributorUpdatedEntity
} from "../generated/schema"

export function handleSetupCompleted(event: SetupCompleted): void {
  // Create or update Vault entity
  let vault = Vault.load(event.address.toHexString())
  if (vault == null) {
    vault = new Vault(event.address.toHexString())
    vault.createdAt = event.block.timestamp
    vault.totalSupply = BigInt.fromI32(0)
    vault.totalAssets = BigInt.fromI32(0)
  }
  vault.setupCompleted = true
  vault.updatedAt = event.block.timestamp
  vault.save()

  // Create SetupCompleted event entity
  let setupCompleted = new SetupCompletedEntity(
    event.transaction.hash.toHexString() + "-" + event.logIndex.toString()
  )
  setupCompleted.setupAddress = event.params.setupAddress
  setupCompleted.blockNumber = event.block.number
  setupCompleted.blockTimestamp = event.block.timestamp
  setupCompleted.transactionHash = event.transaction.hash
  setupCompleted.save()
}

export function handleTimelockUpdated(event: TimelockUpdated): void {
  // Update Vault entity
  let vault = Vault.load(event.address.toHexString())
  if (vault != null) {
    vault.timelock = event.params.timelock
    vault.updatedAt = event.block.timestamp
    vault.save()
  }

  // Create TimelockUpdated event entity
  let timelockUpdated = new TimelockUpdatedEntity(
    event.transaction.hash.toHexString() + "-" + event.logIndex.toString()
  )
  timelockUpdated.timelock = event.params.timelock
  timelockUpdated.blockNumber = event.block.number
  timelockUpdated.blockTimestamp = event.block.timestamp
  timelockUpdated.transactionHash = event.transaction.hash
  timelockUpdated.save()
}

export function handleProvidersUpdated(event: ProvidersUpdated): void {
  // Update Vault entity
  let vault = Vault.load(event.address.toHexString())
  if (vault != null) {
    vault.updatedAt = event.block.timestamp
    vault.save()
  }

  // Create ProvidersUpdated event entity
  let providersUpdated = new ProvidersUpdatedEntity(
    event.transaction.hash.toHexString() + "-" + event.logIndex.toString()
  )
  // Convert Address array to Bytes array
  let providers = new Array<Bytes>()
  for (let i = 0; i < event.params.providers.length; i++) {
    providers.push(event.params.providers[i] as Bytes)
  }
  providersUpdated.providers = providers
  providersUpdated.blockNumber = event.block.number
  providersUpdated.blockTimestamp = event.block.timestamp
  providersUpdated.transactionHash = event.transaction.hash
  providersUpdated.save()
}

export function handleActiveProviderUpdated(event: ActiveProviderUpdated): void {
  // Update Vault entity
  let vault = Vault.load(event.address.toHexString())
  if (vault != null) {
    vault.activeProvider = event.params.activeProvider
    vault.updatedAt = event.block.timestamp
    vault.save()
  }

  // Create ActiveProviderUpdated event entity
  let activeProviderUpdated = new ActiveProviderUpdatedEntity(
    event.transaction.hash.toHexString() + "-" + event.logIndex.toString()
  )
  activeProviderUpdated.activeProvider = event.params.activeProvider
  activeProviderUpdated.blockNumber = event.block.number
  activeProviderUpdated.blockTimestamp = event.block.timestamp
  activeProviderUpdated.transactionHash = event.transaction.hash
  activeProviderUpdated.save()
}

export function handleTreasuryUpdated(event: TreasuryUpdated): void {
  // Update Vault entity
  let vault = Vault.load(event.address.toHexString())
  if (vault != null) {
    vault.treasury = event.params.treasury
    vault.updatedAt = event.block.timestamp
    vault.save()
  }

  // Create TreasuryUpdated event entity
  let treasuryUpdated = new TreasuryUpdatedEntity(
    event.transaction.hash.toHexString() + "-" + event.logIndex.toString()
  )
  treasuryUpdated.treasury = event.params.treasury
  treasuryUpdated.blockNumber = event.block.number
  treasuryUpdated.blockTimestamp = event.block.timestamp
  treasuryUpdated.transactionHash = event.transaction.hash
  treasuryUpdated.save()
}

export function handleWithdrawFeePercentUpdated(event: WithdrawFeePercentUpdated): void {
  // Update Vault entity
  let vault = Vault.load(event.address.toHexString())
  if (vault != null) {
    vault.withdrawFeePercent = event.params.withdrawFeePercent
    vault.updatedAt = event.block.timestamp
    vault.save()
  }

  // Create WithdrawFeePercentUpdated event entity
  let withdrawFeePercentUpdated = new WithdrawFeePercentUpdatedEntity(
    event.transaction.hash.toHexString() + "-" + event.logIndex.toString()
  )
  withdrawFeePercentUpdated.withdrawFeePercent = event.params.withdrawFeePercent
  withdrawFeePercentUpdated.blockNumber = event.block.number
  withdrawFeePercentUpdated.blockTimestamp = event.block.timestamp
  withdrawFeePercentUpdated.transactionHash = event.transaction.hash
  withdrawFeePercentUpdated.save()
}

export function handleMinAmountUpdated(event: MinAmountUpdated): void {
  // Update Vault entity
  let vault = Vault.load(event.address.toHexString())
  if (vault != null) {
    vault.minAmount = event.params.minAmount
    vault.updatedAt = event.block.timestamp
    vault.save()
  }

  // Create MinAmountUpdated event entity
  let minAmountUpdated = new MinAmountUpdatedEntity(
    event.transaction.hash.toHexString() + "-" + event.logIndex.toString()
  )
  minAmountUpdated.minAmount = event.params.minAmount
  minAmountUpdated.blockNumber = event.block.number
  minAmountUpdated.blockTimestamp = event.block.timestamp
  minAmountUpdated.transactionHash = event.transaction.hash
  minAmountUpdated.save()
}

export function handleFeeCharged(event: FeeCharged): void {
  // Create Fee entity
  let fee = new Fee(
    event.transaction.hash.toHexString() + "-" + event.logIndex.toString()
  )
  fee.vault = event.address.toHexString()
  fee.treasury = event.params.treasury
  fee.assets = event.params.assets
  fee.fee = event.params.fee
  fee.blockNumber = event.block.number
  fee.blockTimestamp = event.block.timestamp
  fee.transactionHash = event.transaction.hash
  fee.save()

  // Create FeeCharged event entity
  let feeCharged = new FeeChargedEntity(
    event.transaction.hash.toHexString() + "-" + event.logIndex.toString()
  )
  feeCharged.treasury = event.params.treasury
  feeCharged.assets = event.params.assets
  feeCharged.fee = event.params.fee
  feeCharged.blockNumber = event.block.number
  feeCharged.blockTimestamp = event.block.timestamp
  feeCharged.transactionHash = event.transaction.hash
  feeCharged.save()
}

export function handleRebalanceExecuted(event: RebalanceExecuted): void {
  // Create Rebalance entity
  let rebalance = new Rebalance(
    event.transaction.hash.toHexString() + "-" + event.logIndex.toString()
  )
  rebalance.vault = event.address.toHexString()
  rebalance.assetsFrom = event.params.assetsFrom
  rebalance.assetsTo = event.params.assetsTo
  rebalance.from = event.params.from
  rebalance.to = event.params.to
  rebalance.blockNumber = event.block.number
  rebalance.blockTimestamp = event.block.timestamp
  rebalance.transactionHash = event.transaction.hash
  rebalance.save()

  // Create RebalanceExecuted event entity
  let rebalanceExecuted = new RebalanceExecutedEntity(
    event.transaction.hash.toHexString() + "-" + event.logIndex.toString()
  )
  rebalanceExecuted.assetsFrom = event.params.assetsFrom
  rebalanceExecuted.assetsTo = event.params.assetsTo
  rebalanceExecuted.from = event.params.from
  rebalanceExecuted.to = event.params.to
  rebalanceExecuted.blockNumber = event.block.number
  rebalanceExecuted.blockTimestamp = event.block.timestamp
  rebalanceExecuted.transactionHash = event.transaction.hash
  rebalanceExecuted.save()
}

export function handleRewardsTransferred(event: RewardsTransferred): void {
  // Create RewardsTransferred event entity
  let rewardsTransferred = new RewardsTransferredEntity(
    event.transaction.hash.toHexString() + "-" + event.logIndex.toString()
  )
  rewardsTransferred.to = event.params.to
  rewardsTransferred.amount = event.params.amount
  rewardsTransferred.blockNumber = event.block.number
  rewardsTransferred.blockTimestamp = event.block.timestamp
  rewardsTransferred.transactionHash = event.transaction.hash
  rewardsTransferred.save()
}

export function handleDistributorUpdated(event: DistributorUpdated): void {
  // Create DistributorUpdated event entity
  let distributorUpdated = new DistributorUpdatedEntity(
    event.transaction.hash.toHexString() + "-" + event.logIndex.toString()
  )
  distributorUpdated.rewardsDistributor = event.params.rewardsDistributor
  distributorUpdated.blockNumber = event.block.number
  distributorUpdated.blockTimestamp = event.block.timestamp
  distributorUpdated.transactionHash = event.transaction.hash
  distributorUpdated.save()
}
