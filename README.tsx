/** @jsxImportSource jsx-md */

import { existsSync, readFileSync, readdirSync } from "fs";
import { join, resolve } from "path";

import {
  Badge,
  Badges,
  Bold,
  Center,
  Code,
  CodeBlock,
  Details,
  Heading,
  HR,
  Image,
  Item,
  LineBreak,
  Link,
  List,
  Paragraph,
  Raw,
  Section,
  Sub,
} from "readme";

const REPO_DIR = resolve(import.meta.dirname);
const TASK_DIR = join(REPO_DIR, ".mise/tasks");
const TEST_DIR = join(REPO_DIR, "test");

function read(path: string): string {
  return readFileSync(path, "utf8");
}

function walkFiles(dir: string): string[] {
  if (!existsSync(dir)) return [];

  const files: string[] = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) {
      files.push(...walkFiles(path));
    } else {
      files.push(path);
    }
  }
  return files;
}

function countTests(): number {
  return walkFiles(TEST_DIR).reduce((count, path) => {
    const source = read(path);
    if (path.endsWith(".bats")) {
      return count + (source.match(/@test\s+"/g)?.length ?? 0);
    }
    if (path.endsWith(".py")) {
      return count + (source.match(/^\s*def test_/gm)?.length ?? 0);
    }
    return count;
  }, 0);
}

function configuredLintBadge(): string {
  const miseToml = read(join(REPO_DIR, "mise.toml"));
  const block = miseToml.match(/\[_\.codebase\][\s\S]*?lint\s*=\s*\[([\s\S]*?)\]/)?.[1] ?? "";
  const configured = [...block.matchAll(/"([^"]+)"/g)].map((match) => match[1]);
  return configured.length === 1 && configured[0].startsWith("@")
    ? configured[0]
    : `${configured.length}`;
}

for (const task of ["setup", "new", "search", "changes", "commit", "diff"]) {
  if (!existsSync(join(TASK_DIR, task))) {
    throw new Error(`README workflow references missing task: ${task}`);
  }
}

const testCount = countTests();
const lintBadge = configuredLintBadge();

const readme = (
  <>
    <Center>
      <Image
        src="assets/manly-love.webp"
        alt="Graffiti reading: For manly love be here March 25th at 2:15 AM sharp"
        width={800}
      />
      <Raw>{`\n\n`}</Raw>
      <Heading level={1}>notes</Heading>
      <Paragraph><Bold>Collective memory, encrypted.</Bold></Paragraph>
      <Badges>
        <Badge label="tests" value={`${testCount}`} color="brightgreen" href="test/" />
        <Badge label="lints" value={lintBadge} color="blue" />
        <Badge label="license" value="MIT" color="blue" href="LICENSE" />
      </Badges>
    </Center>

    <Paragraph>
      Write normal Markdown under <Code>notes/</Code>.
      Notes keeps readable names in your working tree while Git stores encrypted
      content under opaque filenames. Explicit commands handle the moments where
      those two views meet: setup, review, staging, commits, and conflicts.
    </Paragraph>

    <Section title="Install">
      <Paragraph>Install the command for your user:</Paragraph>
      <CodeBlock lang="bash">{`shiv install notes`}</CodeBlock>
      <Paragraph>Or declare it for a project:</Paragraph>
      <CodeBlock lang="toml">{`[plugins]
shiv = "https://github.com/KnickKnackLabs/vfox-shiv"

[tools]
"shiv:notes" = "0.9"`}</CodeBlock>
      <CodeBlock lang="bash">{`mise install`}</CodeBlock>
    </Section>

    <Section title="Run">
      <CodeBlock lang="bash">{`# Initialize encrypted notes and install the Git hooks.
notes setup --yes

# Work with ordinary Markdown.
notes new --slug project-plan --title "Project plan" --tags planning
notes search "project plan"
notes read project-plan

# Review and commit through the readable/obfuscated boundary.
notes changes --summary
notes commit -m "notes: add project plan" notes/project-plan.md
notes diff HEAD~1..HEAD`}</CodeBlock>
    </Section>

    <Details summary="Operational notes">
      <List>
        <Item>Join an existing encrypted repo with <Code>notes setup --yes --unlock</Code>.</Item>
        <Item><Code>setup</Code>, <Code>lock</Code>, <Code>install-hooks</Code>, and <Code>unlock --force</Code> require explicit confirmation.</Item>
        <Item>Prefer <Code>notes commit</Code> for note-only work; use <Code>notes stage</Code> when you need manual Git control.</Item>
        <Item><Code>notes read</Code> strips YAML frontmatter by default; use <Code>--with-frontmatter</Code> to preserve the exact source or <Code>--json</Code> for parsed components. Proposed tail blocks remain ordinary body Markdown until their convention is settled.</Item>
        <Item>Before publishing a ref, run <Code>notes verify-blobs --ref HEAD --strict</Code> to prove its managed blobs are encrypted and local note changes are absent.</Item>
        <Item><Code>notes lock</Code> currently locks every git-crypt path in the repository, not only <Code>notes/</Code>.</Item>
        <Item>Use <Code>notes conflicts</Code> or <Code>notes merge --dry-run</Code> to materialize readable conflict artifacts.</Item>
      </List>
    </Details>

    <Section title="Documentation">
      <Paragraph>
        Run <Code>notes --help</Code> for the complete command surface.
        See <Link href="CONTRIBUTING.md">CONTRIBUTING.md</Link> for repository
        structure, encryption safety boundaries, and validation.
      </Paragraph>
    </Section>

    <Center>
      <HR />
      <Sub>
        Tiny encrypted filing cabinet, very serious about labels.
        <LineBreak />
        <Raw>{`Generated with <a href="https://github.com/KnickKnackLabs/readme">readme</a>`}</Raw>
      </Sub>
    </Center>
  </>
);

console.log(readme);
