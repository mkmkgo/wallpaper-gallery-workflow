import process from 'node:process'
import { execSync } from 'node:child_process'

const CDN_DOMAINS = ['cdn.jsdmirror.com', 'testingcf.jsdelivr.net', 'cdn.jsdelivr.net']
const PRIMARY_CDN = CDN_DOMAINS[0]

const CDN_VERSION = process.env.CDN_VERSION
const IMAGE_REPO_PATH = process.env.IMAGE_REPO_PATH || './nuanXinProPic'

const CONCURRENCY = 8
const WARMUP_TIMEOUT = 15000

function findNewImagePaths() {
  const imageExts = /\.(webp|jpg|jpeg|png)$/i
  const paths = new Set()

  try {
    const output = execSync(
      `git -C "${IMAGE_REPO_PATH}" diff --name-only --diff-filter=A HEAD~1..HEAD -- 'thumbnail/' 'preview/' 2>&1`,
    ).toString().trim()

    if (output) {
      for (const line of output.split('\n')) {
        const p = line.trim()
        if (p && imageExts.test(p)) paths.add(p)
      }
    }
  } catch {
    try {
      const output = execSync(
        `git -C "${IMAGE_REPO_PATH}" show --name-only --pretty=format: HEAD -- 'thumbnail/' 'preview/' 2>&1`,
      ).toString().trim()

      if (output) {
        for (const line of output.split('\n')) {
          const p = line.trim()
          if (p && imageExts.test(p)) paths.add(p)
        }
      }
    } catch (err) {
      console.log(`⚠️  git diff/show failed: ${err.message}`)
    }
  }

  return [...paths]
}

async function warmupUrl(url) {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), WARMUP_TIMEOUT)

  try {
    const res = await fetch(url, { signal: controller.signal })
    clearTimeout(timer)
    const cacheStatus = res.headers.get('x-cache') || 'unknown'
    return { url, ok: res.ok, status: res.status, cacheStatus }
  } catch (err) {
    clearTimeout(timer)
    return { url, ok: false, status: 0, error: err.message }
  }
}

async function warmupWithConcurrency(urls, concurrency) {
  const results = []
  let hitCount = 0
  let missCount = 0

  for (let i = 0; i < urls.length; i += concurrency) {
    const batch = urls.slice(i, i + concurrency)
    const batchResults = await Promise.allSettled(batch.map(warmupUrl))
    for (const r of batchResults) {
      const result = r.status === 'fulfilled' ? r.value : { ok: false, cacheStatus: 'error' }
      results.push(result)
      if (result.cacheStatus?.includes('HIT')) hitCount++
      else if (result.cacheStatus?.includes('MISS')) missCount++
    }
    process.stdout.write(`\r   Progress: ${results.length}/${urls.length} (HIT: ${hitCount}, MISS: ${missCount})`)
  }
  console.log('')

  return { results, hitCount, missCount }
}

async function main() {
  if (!CDN_VERSION) {
    console.log('⚠️  CDN_VERSION not set, skipping warmup')
    return
  }

  const CDN_BASE = `https://${PRIMARY_CDN}/gh/mkmkgo/nuanXinProPic@${CDN_VERSION}`

  console.log(`\n🔥 CDN Image Warmup (wallpaper-gallery-workflow)`)
  console.log(`   CDN Version: ${CDN_VERSION}`)
  console.log(`   Primary CDN: ${PRIMARY_CDN}`)
  console.log(`   Image Repo: ${IMAGE_REPO_PATH}\n`)

  const newImagePaths = findNewImagePaths()

  if (newImagePaths.length === 0) {
    console.log('   ℹ️  No new images found, nothing to warmup')
    return
  }

  const imageUrls = newImagePaths.map(p => `${CDN_BASE}/${p}`)
  console.log(`   🖼️  Found ${newImagePaths.length} new images\n`)

  const { results, hitCount, missCount } = await warmupWithConcurrency(imageUrls, CONCURRENCY)

  const success = results.filter(r => r.ok).length
  const failed = results.filter(r => !r.ok).length

  console.log(`\n   ✅ Success: ${success}, Failed: ${failed}`)
  console.log(`   📊 Cache: ${hitCount} HIT, ${missCount} MISS`)

  if (failed > 0) {
    console.log('\n   ❌ Failed URLs (first 5):')
    results.filter(r => !r.ok).slice(0, 5).forEach(r => {
      console.log(`      ${r.status || 'timeout'} - ${r.url}`)
    })
  }

  console.log('\n🏁 CDN Image Warmup Done\n')
}

main()
