@{
    # CI fails on Error severity only. Warnings are reported in the job log but do
    # not fail the build: the bulk of them are PSAvoidUsingWriteHost, and both
    # tools are interactive operator consoles where coloured host output is the
    # point, not an accident.
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # Three call sites, all converting a password this code generated a moment
        # earlier (per-user initial passwords, the DSRM password) into the
        # SecureString that New-ADUser and Install-ADDSForest require. There is no
        # encrypted form to start from - the value is created in memory - so the
        # rule's suggested alternative does not apply. The plaintext never reaches
        # a file: user passwords go to an ACL-restricted handover file and the
        # DSRM password is stored with machine-scoped DPAPI.
        'PSAvoidUsingConvertToSecureStringWithPlainText'
    )
}
