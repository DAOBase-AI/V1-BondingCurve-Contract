// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// When running the script with `npx hardhat run <script>` you'll find the Hardhat
// Runtime Environment's members available in the global scope.
const hre = require('hardhat')

async function main() {
  const AnalyticMathFactory = await hre.ethers.getContractFactory(
    'AnalyticMath'
  )
  const analyticMath = await AnalyticMathFactory.deploy()
  await analyticMath.deployed()
  await analyticMath.init()

  console.log('analyticMath address: ' + analyticMath.address)
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error)
    process.exit(1)
  })
