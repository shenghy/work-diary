// 让 Node ESM 能直接吃 uni-app 源码里的无扩展名 import（'./api' → './api.js'）
//
// 另外要把 ?case=N 往下传：测试用查询串把每次 fresh() 的模块单例隔开，
// 子依赖若不带同一个 case，同一份源码就会在进程里出现两个实例——
// 模块级缓存（附件记录、设备 id）各写各的，测出来的行为和真机不一致。
export async function resolve(specifier, context, nextResolve) {
  const target = withParentCase(specifier, context)
  try {
    return await nextResolve(target, context)
  } catch (err) {
    if (target.startsWith('.') && !hasFileExt(target)) {
      return await nextResolve(addExt(target), context)
    }
    throw err
  }
}

function splitQuery(specifier) {
  const i = specifier.indexOf('?')
  return i < 0 ? [specifier, ''] : [specifier.slice(0, i), specifier.slice(i)]
}

function hasFileExt(specifier) {
  return /\.[A-Za-z]+$/.test(splitQuery(specifier)[0])
}

function addExt(specifier) {
  const [path, query] = splitQuery(specifier)
  return path + '.js' + query
}

function withParentCase(specifier, context) {
  if (!specifier.startsWith('.')) return specifier
  if (specifier.indexOf('?') >= 0) return specifier
  let caseValue = ''
  try {
    caseValue = new URL(context.parentURL).searchParams.get('case') || ''
  } catch (e) {
    return specifier
  }
  return caseValue ? specifier + '?case=' + caseValue : specifier
}
