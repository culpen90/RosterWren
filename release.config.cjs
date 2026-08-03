const conventionalCommits = {
  preset: "conventionalcommits",
  presetConfig: {},
};

const signingMode = process.env.ROSTERWREN_SIGNING_MODE;
const distributionNotice = signingMode === "adhoc"
  ? "> [!WARNING]\n> This release uses an ad-hoc development signature and is not Apple-notarized."
  : signingMode === "developer-id"
    ? "The downloadable app is Developer ID signed and Apple-notarized."
    : "The release workflow verifies its signing policy before publication.";

module.exports = {
  branches: ["main"],
  tagFormat: "v${version}",
  plugins: [
    ["@semantic-release/commit-analyzer", conventionalCommits],
    ["@semantic-release/release-notes-generator", conventionalCommits],
    [
      "@semantic-release/github",
      {
        assets: [
          {
            path: "dist/RosterWren-*-macOS-universal.dmg",
            label: "Universal macOS disk image",
          },
          {
            path: "dist/RosterWren-*-macOS-universal.zip",
            label: "Universal macOS application",
          },
          {
            path: "dist/RosterWren-*-dSYMs.zip",
            label: "Debug symbols",
          },
          {
            path: "dist/RosterWren-*-SHA256SUMS.txt",
            label: "SHA-256 checksums",
          },
        ],
        releaseNameTemplate: "RosterWren <%= nextRelease.version %>",
        releaseBodyTemplate:
          "Download **`RosterWren-<%= nextRelease.version %>-macOS-universal.dmg`** "
          + "and drag RosterWren to Applications.\n\n"
          + "<%= nextRelease.notes %>\n\n"
          + "<!-- rosterwren-distribution-start -->\n"
          + `${distributionNotice}\n`
          + "<!-- rosterwren-distribution-end -->\n\n"
          + "### Verify the download\n\n"
          + "Use `RosterWren-<%= nextRelease.version %>-SHA256SUMS.txt` to "
          + "verify the DMG, app ZIP, and dSYM archive before use.",
        draftRelease: true,
        successCommentCondition: false,
        failCommentCondition: false,
        releasedLabels: false,
        addReleases: false,
      },
    ],
    [
      "@semantic-release/exec",
      {
        prepareCmd: "./scripts/package-release.sh ${nextRelease.version}",
        successCmd:
          "./scripts/publish-release-draft.sh ${nextRelease.gitTag} dist ${nextRelease.gitHead}",
      },
    ],
  ],
};
