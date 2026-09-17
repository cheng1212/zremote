// phase 判定与错误人话 —— 回归锁。
//
// 锁住的坑：
// · `queued` 必须算「忙」但**不算**「在产出」——排队中给「停止」按钮是错的，
//   停了也没东西可停（Flutter 端旧实现漏了 queued，排队态被当空闲）。
// · 错误值可能是结构体而非字符串，只认字符串会把具体原因全丢掉
//   （BUG-33：余额不足这类 provider 业务错误就是结构体）。
import { describe, expect, it } from 'vitest'
import {
  errorValueText,
  isBusyPhase,
  isErrorPhase,
  isProducingPhase,
  phaseLabel,
} from '../src/lib/phase'

describe('isBusyPhase —— 忙（含排队）', () => {
  it('running / prewarming / queued 都算忙', () => {
    expect(isBusyPhase('running')).toBe(true)
    expect(isBusyPhase('prewarming')).toBe(true)
    expect(isBusyPhase('queued')).toBe(true)
  })

  it('idle / 完成态 / 出错态不算忙', () => {
    expect(isBusyPhase('idle')).toBe(false)
    expect(isBusyPhase('completedSuccess')).toBe(false)
    expect(isBusyPhase('error')).toBe(false)
  })

  it('空相位不算忙（快照还没到）', () => {
    expect(isBusyPhase('')).toBe(false)
  })
})

describe('isProducingPhase —— 真在产出（决定「停止」按钮）', () => {
  it('只有 running / prewarming 能停止', () => {
    expect(isProducingPhase('running')).toBe(true)
    expect(isProducingPhase('prewarming')).toBe(true)
  })

  it('queued 不能停止——排队中还没开始跑，给停止是错的', () => {
    expect(isProducingPhase('queued')).toBe(false)
  })

  it('producing 是 busy 的真子集', () => {
    for (const p of ['running', 'prewarming', 'queued', 'idle', 'error', '']) {
      if (isProducingPhase(p)) expect(isBusyPhase(p)).toBe(true)
    }
    // 且 queued 是反例，证明是真子集
    expect(isBusyPhase('queued')).toBe(true)
    expect(isProducingPhase('queued')).toBe(false)
  })
})

describe('isErrorPhase', () => {
  it('error / completedError 是会话级出错相位', () => {
    expect(isErrorPhase('error')).toBe(true)
    expect(isErrorPhase('completedError')).toBe(true)
    expect(isErrorPhase('completedSuccess')).toBe(false)
    expect(isErrorPhase('idle')).toBe(false)
  })
})

describe('errorValueText —— 错误值 → 人话', () => {
  it('纯字符串直接返回（去空白）', () => {
    expect(errorValueText('  余额不足  ')).toBe('余额不足')
    expect(errorValueText('   ')).toBeNull()
  })

  it('结构体优先取 message', () => {
    expect(
      errorValueText({ code: 'provider_business', message: '余额不足，请充值', recoverable: true }),
    ).toBe('余额不足，请充值')
  })

  it('无 message 时退到 detail，再退到 code（三级兜底）', () => {
    expect(errorValueText({ code: 'x', detail: '细节' })).toBe('细节')
    expect(errorValueText({ code: 'provider_business' })).toBe('provider_business')
  })

  it('null / undefined / 数字 / 数组返回 null（不编内容）', () => {
    expect(errorValueText(null)).toBeNull()
    expect(errorValueText(undefined)).toBeNull()
    expect(errorValueText(42)).toBeNull()
    expect(errorValueText(['a'])).toBeNull()
  })

  it('结构体里字段不是字符串时继续往下找', () => {
    expect(errorValueText({ message: 123, detail: '真的原因' })).toBe('真的原因')
  })
})

describe('phaseLabel', () => {
  it('已知相位给中文', () => {
    expect(phaseLabel('running')).toBe('运行中')
    expect(phaseLabel('queued')).toBe('排队中')
    expect(phaseLabel('idle')).toBe('空闲')
    expect(phaseLabel('completedError')).toBe('出错')
  })

  it('未知相位原样透传（不吞信息，方便发现服务端新增相位）', () => {
    expect(phaseLabel('weirdNewPhase')).toBe('weirdNewPhase')
    expect(phaseLabel('')).toBe('')
  })
})
