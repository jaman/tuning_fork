%{
  configs: [
    %{
      name: "default",
      strict: true,
      files: %{included: ["lib/", "test/"], excluded: ["lib/tuning_fork/pattern/voicing/", "lib/tuning_fork/gm/"]},
      checks: %{
        extra: [
          {Credo.Check.Design.AliasUsage,
           [if_nested_deeper_than: 2, if_called_more_often_than: 0, files: %{excluded: ["lib/tuning_fork/sonic_pi.ex"]}]}
        ]
      }
    }
  ]
}
