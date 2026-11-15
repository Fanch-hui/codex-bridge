/** The note appended to an isolated child's result so the parent knows where its changes stand. */
export function workspaceNotice(result) {
  if (result.workspaceMode !== 'isolated') return '';
  const status = result.workspaceStatus ?? 'pending';
  const guidance = {
    pending: 'Changes are waiting to be merged into the project.',
    merged: 'Changes have been merged into the project.',
    conflict: 'Changes have conflicts and remain in the isolated workspace; use bridge_agent_changes to inspect them.',
    retained: 'Changes remain in the isolated workspace and have not been merged.',
    failed: 'The merge failed; changes remain in the isolated workspace.',
    validation_required: 'Changes await successful project validation. Use the workbench recovery area to configure checks or retry validation.',
    recovery_required: 'A partial merge needs recovery. Project writes are paused; use the workbench recovery area to finish or roll back the merge.'
  }[status] ?? `Workspace status: ${status}.`;
  const headline = result.workspaceUnavailable === true
    ? 'The isolated workspace no longer exists, so its unmerged changes cannot be read. The record is kept and was not marked as discardable.' : guidance;
  const detail = { workspaceStatus: status,
    ...(result.workspacePath ? { workspacePath: result.workspacePath } : {}),
    ...(result.changedFiles ? { changedFiles: result.changedFiles } : {}),
    ...(result.conflicts ? { conflicts: result.conflicts } : {}),
    ...(result.failureReason ? { failureReason: result.failureReason } : {}),
    ...(result.workspaceUnavailable === true ? { workspaceUnavailable: true } : {}),
    ...(result.changedFilesOmitted === undefined ? {} : { changedFilesOmitted: result.changedFilesOmitted }),
    ...(result.conflictsOmitted === undefined ? {} : { conflictsOmitted: result.conflictsOmitted }),
    ...(result.excludedPaths?.length ? { excludedPaths: result.excludedPaths } : {}),
    ...(result.excludedPathsOmitted ? { excludedPathsOmitted: result.excludedPathsOmitted } : {}) };
  // Excluded directories and secret files never leave the isolated workspace, so the parent must be told.
  const excluded = result.excludedPaths?.length || result.excludedPathsOmitted
    ? '\nPaths listed in excludedPaths were written in the isolated workspace but are never merged into the project.' : '';
  return `${headline}${excluded}\n${JSON.stringify(detail)}`;
}
