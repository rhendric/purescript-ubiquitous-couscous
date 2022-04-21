#!/bin/bash

set -ex

# Provides expanders that group console output in GitHub Actions
# See https://docs.github.com/en/actions/reference/workflow-commands-for-github-actions#grouping-log-lines
(echo "::group::Initialize variables") 2>/dev/null

# This is the main CI build script. It is intended to run on all platforms we
# run CI on: linux, mac os, and windows. It makes use of the following
# environment variables:
#
# - CI_RELEASE
#
#   If set to "true", passes the RELEASE flag to the compiler, and enables
#   optimizations. Otherwise, we disable optimizations (to speed builds up).
#
# = Source distributions
#
# During a normal build, we create a source distribution with `stack sdist`,
# and then compile and run tests inside that. The reason for this is that it
# helps catch issues arising from forgetting to list files which are necessary
# for compilation or for tests in our package.yaml file (these sorts of issues
# don't test to get noticed until after releasing otherwise).

# We test with --haddock because haddock generation can fail if there is invalid doc-comment syntax,
# and these failures are very easy to miss otherwise.
STACK="stack --no-terminal --haddock --jobs=2"

STACK_OPTS="--test"
if [ "$CI_RELEASE" = "true" ]
then
  STACK_OPTS="$STACK_OPTS --flag=purescript:RELEASE"
else
  STACK_OPTS="$STACK_OPTS --fast"
fi

(echo "::endgroup::"; echo "::group::Determine release version") 2>/dev/null

pushd npm-package

last_tag=$(git ls-remote --tags -q --sort=-version:refname | head -n 1 | cut -f2 | sed 's_refs/tags/__')
package_version=$(node -pe 'require("./package.json").version')

if ! grep -q "^version:\\s*${package_version//./\\.}$" ../purescript.cabal
then
  echo "Version in npm-package/package.json doesn't match version in purescript.cabal"
  exit 1
fi

if [ "$last_tag" = "v$package_version" -a "$CI_PRERELEASE" = "true" ]
then
  if [[ "$package_version" = *-* ]]
  then
    # A hyphen indicates a prerelease version. We are already preparing for the
    # specified release; don't bother bumping any higher version numbers,
    # regardless of what's in the changelog.
    bump=prerelease
  elif [ "$(echo ../CHANGELOG.d/breaking_*)" ]
  then
    # If we ever reach 1.0, change this to premajor
    bump=preminor
  elif [ "$(echo ../CHANGELOG.d/feature_*)" ]
  then
    # If we ever reach 1.0, change this to preminor
    bump=prerelease
  else
    bump=prerelease
  fi
  tag=$(npm version --no-git-tag-version "$bump")
  prerelease_version=${tag#v}
  sed -i -e "s/${package_version//./\\.}/$prerelease_version/g" package.json ../purescript.cabal
  echo "::set-output name=version::$tag"
else
  echo "::set-output name=version::v$package_version"
fi

popd

(echo "::endgroup::"; echo "::group::Install snapshot dependencies") 2>/dev/null

# Install snapshot dependencies (since these will be cached globally and thus
# can be reused during the sdist build step)
$STACK build --only-snapshot $STACK_OPTS

(echo "::endgroup::"; echo "::group::Build source distributions") 2>/dev/null

# Test in a source distribution (see above)
$STACK sdist lib/purescript-cst --tar-dir sdist-test/lib/purescript-cst
tar -xzf sdist-test/lib/purescript-cst/purescript-cst-*.tar.gz -C sdist-test/lib/purescript-cst --strip-components=1
$STACK sdist . --tar-dir sdist-test;
tar -xzf sdist-test/purescript-*.tar.gz -C sdist-test --strip-components=1

(echo "::endgroup::"; echo "::group::Build and test PureScript") 2>/dev/null

pushd sdist-test
$STACK build $STACK_OPTS
popd

(echo "::endgroup::") 2>/dev/null
