// 询问交互纯逻辑 —— 回归锁。
//
// 这一组锁住的是实测出来的契约形状（BUG-17）：
// · answers 是**数组**，元素的键是**题干原文**（服务端没有 id）
// · 选项标识是 `value` 不是 `label`
// · selected 是唯一出口，自由文本拼进 selected（没有独立 other 字段）
// 形状错 → 服务端拒收 → 会话永久卡住（服务端在等回答，回合不继续）。
import { describe, expect, it } from 'vitest'
import {
  allAnswered,
  buildAskAnswersPayload,
  emptyAnswers,
  interactionId,
  isPermissionInteraction,
  isQuestionInteraction,
  parseOption,
  parseQuestion,
  parseQuestions,
  payloadAllowsFreeText,
  permissionOptions,
  questionKey,
  toggleOption,
  type AskAnswer,
  type AskQuestion,
} from '../src/lib/ask'

function q(over: Partial<AskQuestion> = {}): AskQuestion {
  return { question: '选哪个？', header: '选哪个？', multiSelect: false, options: [], ...over }
}

describe('parseQuestion / parseOption —— 缺字段给安全默认，绝不抛', () => {
  it('正常形状解析', () => {
    const parsed = parseQuestion({
      question: '用什么模型？',
      header: '模型',
      multiSelect: true,
      options: [{ value: 'glm', label: 'GLM', description: '国产' }],
    })
    expect(parsed).toMatchObject({ question: '用什么模型？', header: '模型', multiSelect: true })
    expect(parsed.options[0]).toEqual({ value: 'glm', label: 'GLM', description: '国产' })
  })

  it('header 缺省时退回题干', () => {
    expect(parseQuestion({ question: '只有题干' }).header).toBe('只有题干')
  })

  it('prompt 可替代 question（服务端两种字段名都出现过）', () => {
    expect(parseQuestion({ prompt: '来自 prompt' }).question).toBe('来自 prompt')
  })

  it('value 与 label 互相兜底', () => {
    expect(parseOption({ label: '只有label' })).toMatchObject({ value: '只有label', label: '只有label' })
    expect(parseOption({ value: 'only-value' })).toMatchObject({ value: 'only-value', label: 'only-value' })
  })

  it('非对象输入返回空结构，不抛', () => {
    expect(parseQuestion(null)).toEqual({ question: '', header: '', multiSelect: false, options: [] })
    expect(parseOption(undefined)).toEqual({ value: '', label: '', description: '' })
    expect(parseQuestions({ payload: { questions: 'oops' } })).toEqual([])
    expect(parseQuestions({})).toEqual([])
  })

  it('multiSelect 只认严格 true（字符串 "true" 不算）', () => {
    expect(parseQuestion({ multiSelect: 'true' }).multiSelect).toBe(false)
    expect(parseQuestion({ multiSelect: true }).multiSelect).toBe(true)
  })
})

describe('questionKey —— 回传键', () => {
  it('用题干原文作键', () => {
    expect(questionKey(q({ question: '题干' }), 0)).toBe('题干')
  })

  it('题干为空时给稳定占位，避免多道空题干题塌到同一个键', () => {
    expect(questionKey(q({ question: '' }), 0)).toBe('#q0')
    expect(questionKey(q({ question: '' }), 1)).toBe('#q1')
  })
})

describe('toggleOption —— 单选可反悔，多选可 toggle', () => {
  const empty: AskAnswer = { selected: [], other: '' }

  it('单选：替换', () => {
    expect(toggleOption(empty, 'a', false).selected).toEqual(['a'])
    expect(toggleOption({ selected: ['a'], other: '' }, 'b', false).selected).toEqual(['b'])
  })

  it('单选：点已选中的则清空（允许反悔）', () => {
    expect(toggleOption({ selected: ['a'], other: '' }, 'a', false).selected).toEqual([])
  })

  it('多选：toggle 加/减', () => {
    const one = toggleOption(empty, 'a', true)
    expect(one.selected).toEqual(['a'])
    const two = toggleOption(one, 'b', true)
    expect(two.selected.sort()).toEqual(['a', 'b'])
    const back = toggleOption(two, 'a', true)
    expect(back.selected).toEqual(['b'])
  })

  it('切选项不动 other', () => {
    expect(toggleOption({ selected: [], other: '自由文本' }, 'a', false).other).toBe('自由文本')
  })

  it('不改原对象（纯函数）', () => {
    const orig: AskAnswer = { selected: [], other: '' }
    toggleOption(orig, 'a', false)
    expect(orig.selected).toEqual([])
  })
})

describe('allAnswered —— 提交门槛', () => {
  it('全答才算过', () => {
    expect(allAnswered([{ selected: ['a'], other: '' }])).toBe(true)
    expect(allAnswered([{ selected: [], other: '填了字' }])).toBe(true)
    expect(allAnswered([{ selected: ['a'], other: '' }, { selected: [], other: '' }])).toBe(false)
  })

  it('空答案数组不算过（没有题就不该提交）', () => {
    expect(allAnswered([])).toBe(false)
  })

  it('空白 other 不算答案', () => {
    expect(allAnswered([{ selected: [], other: '   ' }])).toBe(false)
  })
})

describe('buildAskAnswersPayload —— 契约形状', () => {
  it('answers 是数组、键是题干原文、selected 是数组', () => {
    const payload = buildAskAnswersPayload(
      [q({ question: '模型？' }), q({ question: '模式？' })],
      [
        { selected: ['glm'], other: '' },
        { selected: ['build'], other: '' },
      ],
    )
    expect(payload).toEqual({
      action: 'accept',
      content: {
        answers: [
          { question: '模型？', selected: ['glm'] },
          { question: '模式？', selected: ['build'] },
        ],
      },
    })
  })

  it('自由文本拼进 selected（契约里没有独立 other 字段）', () => {
    const payload = buildAskAnswersPayload([q()], [{ selected: ['a'], other: ' 补充说明 ' }])
    expect(payload.content.answers[0].selected).toEqual(['a', '补充说明'])
  })

  it('只有自由文本时 selected 就是它', () => {
    const payload = buildAskAnswersPayload([q()], [{ selected: [], other: '只有我' }])
    expect(payload.content.answers[0].selected).toEqual(['只有我'])
  })

  it('答案少于题目时缺的补空 selected（不塌数组长度）', () => {
    const payload = buildAskAnswersPayload([q({ question: 'a' }), q({ question: 'b' })], [
      { selected: ['x'], other: '' },
    ])
    expect(payload.content.answers).toHaveLength(2)
    expect(payload.content.answers[1]).toEqual({ question: 'b', selected: [] })
  })

  it('题干为空时用占位键', () => {
    const payload = buildAskAnswersPayload([q({ question: '' })], [{ selected: ['a'], other: '' }])
    expect(payload.content.answers[0].question).toBe('#q0')
  })
})

describe('交互类型判定', () => {
  it('kind=userInput 是 questions 类', () => {
    expect(isQuestionInteraction({ payload: { kind: 'userInput', questions: [] } })).toBe(true)
    expect(isQuestionInteraction({ payload: { kind: 'permission' } })).toBe(false)
  })

  it('kind=permission 或带 requestId 是权限类', () => {
    expect(isPermissionInteraction({ payload: { kind: 'permission' } })).toBe(true)
    expect(isPermissionInteraction({ payload: { requestId: 'r1' } })).toBe(true)
    expect(isPermissionInteraction({ payload: { kind: 'userInput' } })).toBe(false)
  })

  it('freeText 只认严格 true', () => {
    expect(payloadAllowsFreeText({ payload: { freeText: true } })).toBe(true)
    expect(payloadAllowsFreeText({ payload: { freeText: 1 } })).toBe(false)
    expect(payloadAllowsFreeText({})).toBe(false)
  })

  it('权限选项缺省给允许/拒绝两态', () => {
    const opts = permissionOptions({ payload: { kind: 'permission' } })
    expect(opts.map((o) => o.value)).toEqual(['allow', 'deny'])
  })

  it('权限选项服务端给了就用服务端的', () => {
    const opts = permissionOptions({
      payload: { kind: 'permission', options: [{ value: 'once', label: '仅本次' }] },
    })
    expect(opts.map((o) => o.value)).toEqual(['once'])
  })

  it('interactionId 兼容 requestId 字段名', () => {
    expect(interactionId({ interactionId: 'a' })).toBe('a')
    expect(interactionId({ requestId: 'b' })).toBe('b')
    expect(interactionId({})).toBe('')
  })
})

describe('emptyAnswers', () => {
  it('按题目数造空答案', () => {
    expect(emptyAnswers(2)).toEqual([
      { selected: [], other: '' },
      { selected: [], other: '' },
    ])
    expect(emptyAnswers(0)).toEqual([])
  })
})
