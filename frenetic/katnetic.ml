open PolicyGenerator
open Async_parallel.Std

let help args =
  match args with 
    | [ "run" ] -> 
      Format.printf 
        "@[usage: katnetic run [local|automaton] <filename> @\n@]"
    | [ "dump" ] -> 
      Format.printf 
        "@[usage: katnetic dump automaton [all|policies|flowtables] <filename> @\n@]";
      Format.printf 
        "@[usage: katnetic dump local [all|policies|flowtables] <number of switches> <filename> @\n@]"
    | _ -> 
      Format.printf "@[usage: katnetic <command> @\n%s@\n%s@\n@]"
	"  run    Compile and start the controller"  
	"  dump   Compile and dump flow table"

module Run = struct
  open LocalCompiler

  let with_channel f chan =
    let open Core.Std in
    let open Async.Std in
    let exp = NetKAT_Parser.program NetKAT_Lexer.token (Lexing.from_channel chan) in
    let main () = ignore (Async_Controller.start_static f 6633 exp) in
    never_returns (Scheduler.go_main ~max_num_open_file_descrs:4096 ~main ())

  let with_file f filename =
    with_channel f (open_in filename)

  let local p =
    (fun sw -> to_table (compile sw p))

  let automaton p =
    let open NetKAT_Automaton in
    let open NetKAT_Types in
    let i,m,_,e = dehopify p in
    let cache = SwitchMap.mapi (fun sw sw_p ->
      let sw_p' = NetKAT_Types.(Seq(Seq(i,sw_p),e)) in
      to_table (compile sw sw_p'))
    m in
    (fun sw -> SwitchMap.find sw cache)

  let main args =
    match args with
      | [filename]
      | ("local"     :: [filename]) -> with_file local filename
      | ("automaton" :: [filename]) -> with_file automaton filename
      | _ -> help [ "run" ]
end

module Dump = struct
  open LocalCompiler

  let with_channel f chan =
    f (NetKAT_Parser.program NetKAT_Lexer.token (Lexing.from_channel chan))

  let with_file f filename =
    with_channel f (open_in filename)

  module Local = struct

    let with_compile (sw : VInt.t) (p : NetKAT_Types.policy) =
      let _ = 
        Format.printf "@[Compiling switch %ld [size=%d]...@]%!"
          (VInt.get_int32 sw) (Semantics.size p) in
      let t1 = Unix.gettimeofday () in
      let i = compile sw p in
      let t2 = Unix.gettimeofday () in
      let t = to_table i in
      let t3 = Unix.gettimeofday () in
      let _ = Format.printf "@[Done [ctime=%fs ttime=%fs tsize=%d]@\n@]%!"
        (t2 -. t1) (t3 -. t2) (List.length t) in
      t

    let flowtable (sw : VInt.t) t =
      if List.length t > 0 then
        Format.printf "@[flowtable for switch %ld:@\n%a@\n@\n@]%!"
          (VInt.get_int32 sw)
          SDN_Types.format_flowTable t

    let policy p =
      Format.printf "@[%a@\n@\n@]%!" NetKAT_Pretty.format_policy p

    let local f sw_num p =
      (* NOTE(seliopou): This may not catch all ports, but it'll catch some of
       * 'em! Also, lol for loop.
       * *)
      for sw = 0 to sw_num do
        let vs = VInt.Int64 (Int64.of_int sw) in 
        let sw_p = NetKAT_Types.(Seq(Filter(Test(Switch,vs)), p)) in 
        let t = with_compile vs sw_p in
        f vs t
      done

    let all sw_num p =
      policy p;
      local flowtable sw_num p

    let stats sw_num p =
      local (fun x y -> ()) sw_num p

    let main args =
      match args with
        | (sw_num :: [filename])
        | ("all"        :: [sw_num; filename]) -> with_file (all (int_of_string sw_num)) filename
        | ("policies"   :: [sw_num; filename]) -> with_file policy filename
        | ("flowtables" :: [sw_num; filename]) -> with_file (local flowtable (int_of_string sw_num)) filename
        | ("stats"      :: [sw_num; filename]) -> with_file (stats (int_of_string sw_num)) filename
        | _ -> 
          Format.printf 
            "@[usage: katnetic dump local [all|policies|flowtables|stats] <number of switches> <filename>@\n@]%!"
  end

  module Dist = struct

    open DistributedCompiler
    open Core.Std
    open Async.Std

    let main = function
      | ["stats"; config_file; num_sw; filename] ->
          let config = parse_config config_file in
          let min_sw = 0 in
          let max_sw = Int.of_string num_sw in
          Parallel.init ~cluster:{ Cluster.master_machine = Unix.gethostname();
                                   Cluster.worker_machines = config.workers } ();
          with_file (fun pol ->
            let _ = dist_compiler pol ~min_sw ~max_sw ~config
                >>= fun () ->
                Shutdown.exit 0 in
            never_returns (Scheduler.go ()))
            filename
      | _ -> 
        print_endline "usage: katnetic dump dist stats <cluster.conf> \
          <number of switches> <filename>"

  end

  module Automaton = struct
    open NetKAT_Automaton

    let with_dehop f p =
      let i,m,_,e = dehopify p in
      SwitchMap.iter (fun sw pol0 ->
        let open NetKAT_Types in
        let pol0' = Seq(Seq(i,pol0),e) in
        f sw pol0')
      m

    let policy (sw : VInt.t) (p : NetKAT_Types.policy) : unit =
      Format.printf "@[policy for switch %ld:@\n%!%a@\n@\n@]%!"
        (VInt.get_int32 sw)
        NetKAT_Pretty.format_policy p

    let flowtable (sw : VInt.t) (p : NetKAT_Types.policy) : unit =
      let t = Local.with_compile sw p in
      Local.flowtable sw t

    let all (sw : VInt.t) (p : NetKAT_Types.policy) : unit =
      policy sw p;
      flowtable sw p


    let stats (sw : VInt.t) (p : NetKAT_Types.policy) : unit =
      let _ = Local.with_compile sw p in
      ()

    let main args =
      match args with
        | [filename]
        | ("all"        :: [filename]) -> with_file (with_dehop all) filename
        | ("policies"   :: [filename]) -> with_file (with_dehop policy) filename
        | ("flowtables" :: [filename]) -> with_file (with_dehop flowtable) filename
        | ("stats"      :: [filename]) -> with_file (with_dehop stats) filename
        | _ -> 
          Format.printf 
            "@[usage: katnetic dump automaton [all|policies|flowtables|stats] <filename>@\n@]%!"
  end

  let main args  =
    match args with
      | ("local"     :: args') -> Local.main args'
      | ("automaton" :: args') -> Automaton.main args'
      | "dist" :: args' -> Dist.main args'
      | _ -> help [ "dump" ]

end

let () = 
  match Array.to_list Sys.argv with
    | (_ :: "run"  :: args) -> Run.main args
    | (_ :: "dump" :: args) -> Dump.main args
    | _ -> 
      if Parallel.is_worker_machine () then
        Parallel.init ()
      else
        help []
