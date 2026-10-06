# Shared by bootstrap/apply.sh and evals/reset.sh. Source it; don't run it.

# render_base: the base kustomization, with the placeholder namespace
# `agentic-ops` rewritten to $NAMESPACE.
#
# perl, not sed: the rewrite needs a word boundary, and BSD sed on macOS has no
# \b. With sed the rename silently did nothing on a Mac, so a custom NAMESPACE
# was applied into agentic-ops instead. perl behaves the same on macOS and Linux.
render_base() {
  kubectl kustomize bootstrap/base \
    | perl -pe "s/\\bagentic-ops\\b/${NAMESPACE:-agentic-ops}/g"
}
