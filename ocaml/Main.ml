open Printf
open OpenFlow0x01Parser
open Platform 
open Unix
open MessagesDef

module RegexController = RegexTest.Make (OpenFlowPlatform)
module Controller = MacLearning.Make (OpenFlowPlatform)

let main () = 
  Sys.catch_break true;
  try 
    OpenFlowPlatform.init_with_port 6633;
    Lwt_main.run (Controller.start ())
  with exn -> 
    Printf.eprintf "[main] exception: %s\n%s\n%!" 
      (Printexc.to_string exn) (Printexc.get_backtrace ());
    OpenFlowPlatform.shutdown ();
    exit 1
      
let _ = main ()
