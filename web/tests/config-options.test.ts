// `getTaskConfigOptions` 返回形状解析 —— 回归锁。
//
// 桌面端会自动升级并改接口（`prepareWorkspace` 整个被删过），所以这里的
// 兜底不是防御性编程，是"服务端换形状时界面不能崩、也不能谎报"。
import { describe, expect, it } from 'vitest'
import {
  GROUP_MODE,
  GROUP_THOUGHT,
  buildModelSelection,
  groupOf,
  modelLabel,
  parseConfigGroups,
} from '../src/lib/configOptions'

const groups = [
  {
    id: 'model',
    currentValue: 'glm-5.3-flash',
    options: [
      { value: 'glm-5.3-flash', name: 'GLM 5.3 Flash', modelProviderName: 'builtin:bigmodel' },
      {
        value: 'nv-nemotron',
        name: 'nv/nv-nemotron-ultra',
        description: '本地代理',
        modelProviderName: 'nv',
      },
    ],
  },
  { id: 'thought_level', currentValue: 'high', options: [{ value: 'high', name: '高' }] },
  { id: 'mode', currentValue: 'build', options: [{ value: 'build', name: '构建' }] },
]

describe('parseConfigGroups', () => {
  it('认裸数组，也认 {configOptions:[…]} 包一层', () => {
    expect(parseConfigGroups(groups).map((g) => g.id)).toEqual([
      'model',
      'thought_level',
      'mode',
    ])
    expect(parseConfigGroups({ configOptions: groups }).length).toBe(3)
  })

  it('当前值叫 currentValue / current / value 都认', () => {
    expect(groupOf(parseConfigGroups([{ id: 'mode', current: 'plan', options: [] }]), 'mode')?.current).toBe(
      'plan',
    )
    expect(
      groupOf(parseConfigGroups([{ id: 'mode', value: 'yolo', options: [] }]), 'mode')?.current,
    ).toBe('yolo')
  })

  it('思考等级组的 id 是下划线 thought_level，不是 camelCase', () => {
    expect(groupOf(parseConfigGroups(groups), GROUP_THOUGHT)?.current).toBe('high')
    expect(groupOf(parseConfigGroups(groups), 'thoughtLevel' as never)).toBe(null)
  })

  it('认不出的形状一律空数组，不抛', () => {
    expect(parseConfigGroups(null)).toEqual([])
    expect(parseConfigGroups('x')).toEqual([])
    expect(parseConfigGroups({ foo: 1 })).toEqual([])
    expect(parseConfigGroups([null, 1, { noId: true }])).toEqual([])
  })

  it('无 value 的选项丢掉（点了也没法回传）', () => {
    const g = parseConfigGroups([{ id: 'model', options: [{ name: '没有值' }, { value: 'ok' }] }])
    expect(g[0].options.map((o) => o.value)).toEqual(['ok'])
  })
})

describe('buildModelSelection', () => {
  const parsed = parseConfigGroups(groups)

  it('provider 取 modelProviderName，三个字段都齐（switchModelConfig 三者必填）', () => {
    expect(buildModelSelection(parsed, 'nv-nemotron')).toEqual({
      provider: 'nv',
      model: 'nv-nemotron',
      thought: 'high',
    })
  })

  it('显式给 thought 时以给的为准', () => {
    expect(buildModelSelection(parsed, 'glm-5.3-flash', 'max')?.thought).toBe('max')
  })

  it('没有 model 组 / 值不在选项里 → null，让调用方决定怎么报错', () => {
    expect(buildModelSelection([], 'x')).toBe(null)
    expect(buildModelSelection(parsed, 'nope')).toBe(null)
  })
})

describe('modelLabel', () => {
  const parsed = parseConfigGroups(groups)

  it('当前值有 name 时用 name，且剥掉 provider/ 前缀避免 "nv/nv-…" 观感', () => {
    expect(modelLabel(parsed)).toBe('GLM 5.3 Flash')
    const other = parseConfigGroups([{ ...groups[0], currentValue: 'nv-nemotron' }])
    expect(modelLabel(other)).toBe('nv-nemotron-ultra')
  })

  it('没有 model 组时空串（UI 自己降级成"模型"）', () => {
    expect(modelLabel(parseConfigGroups([{ id: GROUP_MODE, options: [] }]))).toBe('')
  })
})
