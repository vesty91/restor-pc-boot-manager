@{
    # Politique RESTOR-PC.
    # Error reste bloquant via Severity et via scripts/Test-Repository.ps1.
    # Les warnings restent visibles. Aucune règle n'est masquée par ExcludeRules.
    #
    # Portes de non-régression, appliquées dans Test-Repository.ps1 :
    # - PSAvoidUsingEmptyCatchBlock
    # - PSAvoidAssignmentToAutomaticVariable
    # - PSReviewUnusedParameter
    #
    # Non bloquant par choix :
    # - PSAvoidUsingWriteHost
    #   Write-Host porte les lignes [OK], [WARN] et [ERROR] du terminal.
    # - PSUseSingularNouns
    #   Les fonctions internes existantes gardent leur nom pour ne pas casser les appels.
    # - PSUseShouldProcessForStateChangingFunctions
    #   ShouldProcess est ajouté seulement avant une écriture réelle
    #   (nom GPT Lockpick, entrée RESCUEGRID).
    #   Les constructeurs New-* de build-test-disk.ps1 fabriquent des octets en mémoire
    #   ou une image sous test\. Les retraits de lettres temporaires dans un bloc
    #   finally doivent toujours s'exécuter. Start-QemuSession lance un processus
    #   de test, pas une écriture disque.
    IncludeDefaultRules = $true
    Severity            = @('Error', 'Warning')
}
