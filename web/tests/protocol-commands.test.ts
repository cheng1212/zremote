// T10（收编审计 B4：web 端协议测试首块）：TS 集合与双端共享快照的一致性。
// 快照文件被 Dart 侧（test/protocol_commands_snapshot_test.dart）同样比对——
// 任一端改命令集合而不同步，测试即红。
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import { CAS_COMMANDS, ROW_TARGET_COMMANDS } from '../src/protocol/constants'

const fixturePath = resolve(__dirname, '../../test/fixtures/protocol_commands.json')
const fixture = JSON.parse(readFileSync(fixturePath, 'utf-8')) as {
  casCommands: string[]
  rowTargetCommands: string[]
}

describe('协议命令集合快照锁（与 Dart 侧共享 fixture）', () => {
  it('CAS_COMMANDS 与快照一致', () => {
    expect([...CAS_COMMANDS].sort()).toEqual([...fixture.casCommands].sort())
  })

  it('ROW_TARGET_COMMANDS 与快照一致', () => {
    expect([...ROW_TARGET_COMMANDS].sort()).toEqual([...fixture.rowTargetCommands].sort())
  })

  it('ROW_TARGET_COMMANDS 是 CAS_COMMANDS 的子集（口径自检）', () => {
    for (const cmd of ROW_TARGET_COMMANDS) {
      expect(CAS_COMMANDS.has(cmd), cmd).toBe(true)
    }
  })
})
