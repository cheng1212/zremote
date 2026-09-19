// 新会话模型放行闸门判定 —— 移植 Flutter `composer_logic` 的 3 条判定测试。
//
// 闸门存在的意义：桌面端接受 createSession 后仍可能把模型**回退**成工作区默认
// （provider 不在册 / 本地模型代理没起）。首条消息必须在模型确认落位后才发，
// 否则消息静默进了跑不通的模型，用户重试还会重复发。
import { describe, expect, it } from 'vitest'
import {
  checkModelGate,
  readSnapshotModel,
  sessionModelMatches,
  splitModelValue,
  wantedModel,
} from '../src/lib/modelGate'

describe('splitModelValue', () => {
  it('无斜杠时两边同值，调用方不必判空', () => {
    expect(splitModelValue('glm-4.6')).toEqual(['glm-4.6', 'glm-4.6'])
    expect(splitModelValue('')).toEqual(['', ''])
  })

  it('按最后一个斜杠切分（供应商名里可带斜杠）', () => {
    expect(splitModelValue('nv/nemotron/ultra')).toEqual(['nv/nemotron', 'ultra'])
  })
})

describe('sessionModelMatches', () => {
  it('model 必须一致', () => {
    expect(
      sessionModelMatches({
        curProvider: 'nv',
        curModel: 'nemotron',
        wantProvider: '',
        wantModel: 'nemotron',
      }),
    ).toBe(true)
    expect(
      sessionModelMatches({
        curProvider: 'nv',
        curModel: 'qwen',
        wantProvider: '',
        wantModel: 'nemotron',
      }),
    ).toBe(false)
  })

  it('没请求 provider 就不校验它（服务端可能回填同义 id）', () => {
    expect(
      sessionModelMatches({
        curProvider: 'whatever',
        curModel: 'm',
        wantProvider: '',
        wantModel: 'm',
      }),
    ).toBe(true)
  })

  it('请求了 provider 就必须一致——防同名模型跨供应商回退', () => {
    expect(
      sessionModelMatches({
        curProvider: 'glm',
        curModel: 'flash',
        wantProvider: 'nv',
        wantModel: 'flash',
      }),
    ).toBe(false)
  })
})

describe('wantedModel / readSnapshotModel', () => {
  it('config.model 写成 provider/model 时拆成两半', () => {
    expect(wantedModel({ model: 'nv/nemotron' })).toEqual({
      provider: 'nv',
      model: 'nemotron',
    })
    expect(wantedModel({ provider: 'nv', model: 'nemotron' })).toEqual({
      provider: 'nv',
      model: 'nemotron',
    })
    expect(wantedModel(null)).toEqual({ provider: '', model: '' })
  })

  it('快照缺 config / 字段类型不对时退化成空串，不抛', () => {
    expect(readSnapshotModel(null)).toEqual({ provider: '', model: '', thought: '', mode: '' })
    expect(readSnapshotModel({ config: 42 }).model).toBe('')
    expect(readSnapshotModel({ config: { model: 'm', provider: 'p' } })).toEqual({
      provider: 'p',
      model: 'm',
      thought: '',
      mode: '',
    })
  })
})

describe('checkModelGate', () => {
  it('没请求模型（用工作区默认）直接放行', () => {
    expect(checkModelGate({ config: { model: 'qwen' } }, null).ok).toBe(true)
  })

  it('模型被回退 → 失败，且文案同时给出「置为」和「请求的」两个值', () => {
    const r = checkModelGate(
      { config: { provider: 'qwen', model: 'qwen3.8-flash' } },
      { model: 'nv/nemotron-ultra' },
    )
    expect(r.ok).toBe(false)
    expect(r.reason).toContain('qwen/qwen3.8-flash')
    expect(r.reason).toContain('nv/nemotron-ultra')
    expect(r.reason).toContain('消息未发送')
  })

  it('模型落位 → 放行', () => {
    expect(
      checkModelGate(
        { config: { provider: 'nv', model: 'nemotron-ultra' } },
        { model: 'nv/nemotron-ultra' },
      ).ok,
    ).toBe(true)
  })
})
