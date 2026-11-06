/**
 * Parse a pull request's squash commit the way release-please will, and report
 * when release-please would drop it.
 *
 * In a repo with squash_merge_commit_message = PR_BODY the PR description is
 * the commit body. When release-please's conventional-commit parser throws on
 * a commit, the commit is logged at debug level and skipped: a feat/fix PR
 * merges green and cuts no release.
 *
 * Mirrors release-please 17.3.0 (the version googleapis/release-please-action
 * v4.4.1 bundles), src/commit.ts:
 * - preprocessCommitMessage: a BEGIN_COMMIT_OVERRIDE ... END_COMMIT_OVERRIDE
 *   section of the PR body replaces the commit message.
 * - splitMessages: BEGIN_NESTED_COMMIT blocks and blank-line-separated
 *   conventional paragraphs become separate messages.
 * - parseCommits: parser.parser() from @conventional-commits/parser 0.4.1 on
 *   each message. That call is the only step that throws.
 *
 * The squash commit is not the PR body verbatim. GitHub hard-wraps each body
 * line longer than 72 characters (code points, so an emoji counts once) into
 * words separated by single spaces, which drops the line's indentation and
 * collapses runs of spaces and tabs. Lines inside a fenced code block whose
 * fence starts in column 0 are left alone; an indented fence is wrapped like
 * prose. About 300 real squash commits were checked against this model and
 * matched it byte for byte, apart from the Co-authored-by trailers GitHub
 * appends. The wrap is what puts a mid-sentence call such as `name(` at a line
 * start, where the parser reads the line as a footer and throws.
 *
 * Environment: PR_TITLE, PR_BODY, PR_NUMBER, MODE (warn | error), and
 * GITHUB_STEP_SUMMARY when set. Exit 0 when the message parses or MODE=warn,
 * 1 on a parse error under MODE=error, 2 on bad input.
 */
import { appendFileSync, realpathSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { parser } from '@conventional-commits/parser'

export const WRAP_WIDTH = 72
export const SQUASH_SOURCE = 'the squash commit message'
export const OVERRIDE_SOURCE = 'the BEGIN_COMMIT_OVERRIDE section'

// Only a fence in column 0 stops the wrap.
const FENCE = /^(```|~~~)/
const NEWLINE = /\r\n|\r|\n/
const CONVENTIONAL_PARAGRAPH =
  /\r?\n\r?\n(?=(?:feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(?:\(.*?\))?: )/

/** Width in code points, as GitHub counts it: an emoji is one column. */
const columns = (text) => [...text].length

/**
 * Greedy word wrap of one line, as GitHub does it for squash commit bodies.
 * @param {string} line
 * @param {number} width
 * @returns {string[]}
 */
export function wrapLine(line, width = WRAP_WIDTH) {
  if (columns(line) <= width) return [line]
  const lines = []
  let current = ''
  // Runs of spaces and tabs separate words; wrapped lines keep single spaces.
  // The width test also runs for the first word, so a line whose first word
  // alone is too wide gets an empty line before it.
  for (const word of line.split(/[ \t]+/).filter(Boolean)) {
    if (columns(current) + 1 + columns(word) > width) {
      lines.push(current)
      current = word
    } else current = current === '' ? word : `${current} ${word}`
  }
  lines.push(current)
  return lines
}

/**
 * The PR body as it appears in the squash commit: CRLF normalised, lines
 * longer than `width` wrapped, code blocks under a column-0 fence left alone.
 * @param {string} body
 * @param {number} [width]
 * @returns {string}
 */
export function wrapBody(body, width = WRAP_WIDTH) {
  let inFence = false
  return body
    .replace(/\r\n/g, '\n')
    .split('\n')
    .flatMap((line) => {
      if (FENCE.test(line)) {
        inFence = !inFence
        return [line]
      }
      return inFence ? [line] : wrapLine(line, width)
    })
    .join('\n')
}

/**
 * The squash commit message GitHub builds: `<title> (#<number>)`, a blank
 * line, the wrapped body.
 * @param {{ title: string, number: string | number, body?: string | null }} pr
 * @returns {string}
 */
export function buildSquashMessage({ title, number, body }) {
  const subject = `${title} (#${number})`
  return body?.trim() ? `${subject}\n\n${wrapBody(body)}` : subject
}

/**
 * The BEGIN_COMMIT_OVERRIDE section release-please parses instead of the
 * commit message, or '' when there is none. release-please matches the
 * markers as plain text, so a mention in prose counts.
 * @param {string | null | undefined} body
 * @returns {string}
 */
export function commitOverride(body) {
  return ((body ?? '').split('BEGIN_COMMIT_OVERRIDE')[1] || '').split('END_COMMIT_OVERRIDE')[0].trim()
}

/**
 * release-please's splitMessages: nested commits and conventional paragraphs
 * are parsed as separate commits.
 * @param {string} message
 * @returns {string[]}
 */
export function splitMessages(message) {
  const parts = message.split('BEGIN_NESTED_COMMIT')
  const messages = [parts.shift()]
  for (const part of parts) {
    const [newMessage, ...rest] = part.split('END_NESTED_COMMIT')
    messages.push(newMessage)
    messages[0] = messages[0] + rest.join('END_NESTED_COMMIT')
  }
  const conventionalCommits = messages[0].split(CONVENTIONAL_PARAGRAPH).filter(Boolean)
  return [...conventionalCommits, ...messages.slice(1)]
}

/**
 * Map a parser error back to a line of `message`. `line` is 1-based within
 * `message`; `text` is that line.
 * @param {string} message
 * @param {string} part the split message the parser was given
 * @param {string} error the parser's error message
 * @returns {{ error: string, line: number | null, column: number | null, text: string | null }}
 */
export function locate(message, part, error) {
  const at = error.match(/ at (\d+):(\d+), valid tokens/)
  if (!at) return { error, line: null, column: null, text: null }
  // The parser scans part.trim(); map its line back into the message.
  const start = message.indexOf(part.trim())
  const offset = start < 0 ? 0 : message.slice(0, start).split(NEWLINE).length - 1
  const line = offset + Number(at[1])
  return { error, line, column: Number(at[2]), text: message.split(NEWLINE)[line - 1] ?? null }
}

/**
 * Parse errors release-please would hit on a message, one per split message.
 * @param {string} message
 * @returns {ReturnType<typeof locate>[]}
 */
export function parseErrors(message) {
  const errors = []
  for (const part of splitMessages(message)) {
    try {
      parser(part)
    } catch (err) {
      errors.push(locate(message, part, String(err?.message ?? err)))
    }
  }
  return errors
}

/**
 * What release-please will parse for this PR once it is squash-merged, and
 * the errors it would hit.
 * @param {{ title: string, number: string | number, body?: string | null }} pr
 * @returns {{ source: string, message: string, errors: ReturnType<typeof parseErrors> }}
 */
export function checkPullRequest(pr) {
  const override = commitOverride(pr.body)
  const source = override ? OVERRIDE_SOURCE : SQUASH_SOURCE
  const message = override || buildSquashMessage(pr)
  return { source, message, errors: parseErrors(message) }
}

/** Escape newlines so a parser error such as `unexpected token '\n'` stays on one line. */
const visible = (text) => text.replace(/\r/g, '\\r').replace(/\n/g, '\\n')

/** Workflow-command escaping for an annotation message. */
const annotation = (text) => text.replace(/%/g, '%25').replace(/\r/g, '%0D').replace(/\n/g, '%0A')

const HELP = [
  'release-please would skip this commit, so a feat/fix/perf change would cut no release.',
  'The usual cause is a line whose first word runs into "(" that does not close on the same',
  'line, or that opens a second "(" first, such as `name(` or `a.push(b(c))`. GitHub wraps',
  `the description at ${WRAP_WIDTH} columns when it builds the squash commit, so the line may`,
  'start mid-sentence in the description as written. Reword that sentence, or add a',
  'BEGIN_COMMIT_OVERRIDE ... END_COMMIT_OVERRIDE section with the commit message to use.',
  'Line 1 is the PR title.',
]

function main() {
  const { PR_TITLE, PR_BODY, PR_NUMBER, MODE, GITHUB_STEP_SUMMARY } = process.env
  if (MODE !== 'warn' && MODE !== 'error') {
    console.log(`::error::squash-message-check mode must be warn or error (got '${annotation(MODE ?? '')}')`)
    process.exit(2)
  }
  if (!PR_TITLE || !PR_NUMBER) {
    console.log('::error::PR_TITLE and PR_NUMBER must be set (PR_BODY may be empty).')
    process.exit(2)
  }
  const { source, message, errors } = checkPullRequest({ title: PR_TITLE, number: PR_NUMBER, body: PR_BODY })
  const messageLines = message.split(NEWLINE)
  if (errors.length === 0) {
    console.log(`release-please parses ${source} (${messageLines.length} lines).`)
    return
  }

  const level = MODE === 'error' ? 'error' : 'warning'
  const summary = [`### release-please cannot parse ${source}`, '']
  for (const { error, line, text } of errors) {
    const where = line ? `line ${line}` : 'an unknown line'
    console.log(`::${level}::${annotation(`release-please cannot parse ${source} at ${where}: ${visible(error)}`)}`)
    summary.push(`- ${where}: \`${visible(error)}\``)
    if (!line) continue
    console.log(`Line ${line}: ${text}`)
    console.log(`Context (${source}, lines ${Math.max(1, line - 2)}-${line + 2}):`)
    summary.push('', '```')
    for (let n = Math.max(1, line - 2); n <= Math.min(messageLines.length, line + 2); n++) {
      const row = `${n === line ? '>' : ' '} ${String(n).padStart(4)} | ${messageLines[n - 1]}`
      console.log(row)
      summary.push(row)
    }
    summary.push('```', '')
  }
  if (source === OVERRIDE_SOURCE) {
    const note =
      'The description contains BEGIN_COMMIT_OVERRIDE, so release-please parses the text after it ' +
      'instead of the commit. It matches the marker as plain text: a mention in prose counts.'
    console.log(`\n${note}`)
    summary.push(note, '')
  }
  console.log(['', ...HELP].join('\n'))
  summary.push(HELP.join('\n'), '')
  if (GITHUB_STEP_SUMMARY) appendFileSync(GITHUB_STEP_SUMMARY, `${summary.join('\n')}\n`)
  if (MODE === 'error') process.exit(1)
}

// Node reports import.meta.url with symlinks resolved, so compare real paths:
// on macOS the temp directory sits under the /var -> /private/var symlink, and
// a plain path comparison there skipped main() and exited 0 without checking.
if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) main()
