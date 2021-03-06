
open Merkle
open Values

exception VmTrap
exception VmError

type vm = {
  code : inst array;
  stack : value array;
  memory : Int64.t array;
  break_stack : (int*int) array;
(*  call_stack : (int*int*int) array; *)
  call_stack : int array;
  globals : value array;
  calltable : int array;
  calltable_types : Int64.t array;
  mutable pc : int;
  mutable stack_ptr : int;
  mutable break_ptr : int;
  mutable call_ptr : int;
  mutable memsize : int;
}

let inc_pc vm = vm.pc <- vm.pc+1

let create_vm code = {
  code = Array.of_list code;
  stack = Array.make (16*1024) (i 0);
  memory = Array.make (1024*32) 0L;
  call_stack = Array.make 1024 0;
  break_stack = Array.make 1024 (0,0);
  globals = Array.make 64 (i 0);
  calltable = Array.make 64 (-1);
  calltable_types = Array.make 64 0L;
  pc = 0;
  stack_ptr = 0;
  memsize = 0;
  break_ptr = 0;
  call_ptr = 0;
}

(* microcode *)

type in_code =
 | NoIn
 | Immed
 | GlobalIn
 | StackIn0
 | StackIn1
 | StackInReg
 | StackInReg2
 | ReadPc
 | ReadStackPtr
 | BreakLocIn
 | BreakStackIn
 | BreakLocInReg
 | BreakStackInReg
 | CallIn
 | MemoryIn1
 | MemsizeIn
 | TableIn
 | MemoryIn2

type alu_code =
 | Unary of Ast.unop
 | Convert of Ast.cvtop
 | Binary of Ast.binop
 | Compare of Ast.relop
 | Test of Ast.testop
 | Trap
 | Min
 | CheckJump
 | Nop
 | FixMemory of Types.value_type * (Memory.mem_size * Memory.extension) option
 | CheckJumpForward
 | HandleBrkReturn

type reg =
 | Reg1
 | Reg2
 | Reg3

type out_code =
 | BreakLocOut
 | BreakStackOut
 | StackOutReg1
 | StackOut0
 | StackOut1
 | StackOut2
 | CallOut
 | NoOut
 | GlobalOut
 | MemoryOut1 of Types.value_type * Memory.mem_size option
 | MemoryOut2 of Types.value_type * Memory.mem_size option

type stack_ch =
 | StackRegSub
 | StackReg
 | StackReg2
 | StackReg3
 | StackInc
 | StackDec
 | StackNop
 | StackDec2
 | StackDecImmed

type microp = {
  read_reg1 : in_code;
  read_reg2 : in_code;
  read_reg3 : in_code;
  write1 : reg * out_code;
  write2 : reg * out_code;
  alu_code : alu_code;
  call_ch : stack_ch;
  stack_ch : stack_ch;
  break_ch : stack_ch;
  pc_ch : stack_ch;
  mem_ch : bool;
  immed : value;
}

let noop = {
  read_reg1 = NoIn;
  read_reg2 = NoIn;
  read_reg3 = NoIn;
  write1 = (Reg1, NoOut);
  write2 = (Reg1, NoOut);
  alu_code = Nop;
  call_ch = StackNop;
  stack_ch = StackNop;
  break_ch = StackNop;
  pc_ch = StackInc;
  mem_ch = false;
  immed = I32 Int32.zero;
}

type registers = {
  mutable reg1: value;
  mutable reg2: value;
  mutable reg3: value;
  mutable ireg: value;
(*  mutable op: microp; *)
}

let read_register vm reg = function
 | NoIn -> i 0
 | Immed -> reg.ireg
 | GlobalIn -> vm.globals.(value_to_int reg.reg1)
 | StackIn0 -> vm.stack.(vm.stack_ptr-1)
 | StackIn1 -> vm.stack.(vm.stack_ptr-2)
 | StackInReg -> vm.stack.(vm.stack_ptr-value_to_int reg.reg1)
 | StackInReg2 -> vm.stack.(vm.stack_ptr-value_to_int reg.reg2)
 | ReadPc -> i (vm.pc+1)
 | ReadStackPtr -> i vm.stack_ptr
 | BreakLocIn -> i (fst (vm.break_stack.(vm.break_ptr-1)))
 | BreakStackIn -> i (snd (vm.break_stack.(vm.break_ptr-1)))
 | BreakLocInReg -> i (fst (vm.break_stack.(vm.break_ptr-1-value_to_int reg.reg1)))
 | BreakStackInReg -> i (snd (vm.break_stack.(vm.break_ptr-1-value_to_int reg.reg1)))
 | CallIn -> i vm.call_stack.(vm.call_ptr-1)
 | MemoryIn1 -> I64 vm.memory.((value_to_int reg.reg1+value_to_int reg.ireg) / 8)
 | MemoryIn2 -> I64 vm.memory.((value_to_int reg.reg1+value_to_int reg.ireg) / 8 + 1)
 | MemsizeIn -> i vm.memsize
 | TableIn -> i vm.calltable.(value_to_int reg.reg1)

let get_register regs = function
 | Reg1 -> regs.reg1
 | Reg2 -> regs.reg2
 | Reg3 -> regs.reg3

let get_memory mem loc = Byteutil.mini_memory mem.(loc/8) mem.(loc/8+1)

let memop mem v addr = function
 | None -> Memory.store mem addr 0l v
 | Some sz -> Memory.store_packed sz mem addr 0l v

let write_register vm regs v = function
 | NoOut -> ()
 | GlobalOut -> vm.globals.(value_to_int regs.reg1) <- v
 | CallOut -> vm.call_stack.(vm.call_ptr) <- value_to_int v
 | MemoryOut1 (_,sz) ->
    let loc = value_to_int regs.reg1+value_to_int regs.ireg in
    let mem = get_memory vm.memory loc in
    memop mem v (Int64.of_int (loc-(loc/8)*8)) sz;
    vm.memory.(loc/8) <- fst (Byteutil.Decode.mini_memory mem);
    trace ("Stored " ^ Int64.to_string vm.memory.(loc/8))
 | MemoryOut2 (_,sz) ->
    let loc = value_to_int regs.reg1+value_to_int regs.ireg in
    let mem = get_memory vm.memory loc in
    memop mem v (Int64.of_int (loc-(loc/8)*8)) sz;
    vm.memory.(loc/8+1) <- snd (Byteutil.Decode.mini_memory mem)
 | StackOut0 ->
    trace ("push to stack: " ^ string_of_value v);
    vm.stack.(vm.stack_ptr) <- v
 | StackOut1 ->
    trace ("replace top of stack: " ^ string_of_value v);
    vm.stack.(vm.stack_ptr-1) <- v
 | StackOut2 ->
    trace ("pop to stack: " ^ string_of_value v);
    vm.stack.(vm.stack_ptr-2) <- v
 | StackOutReg1 -> vm.stack.(vm.stack_ptr-value_to_int regs.reg1) <- v
 | BreakLocOut ->
   let (a,b) = vm.break_stack.(vm.break_ptr) in
   vm.break_stack.(vm.break_ptr) <- (value_to_int v, b)
 | BreakStackOut ->
   let (a,b) = vm.break_stack.(vm.break_ptr) in
   vm.break_stack.(vm.break_ptr) <- (a, value_to_int v)

let setup_memory vm m instance =
  let open Ast in
  let open Types in
  let open Source in
  List.iter (function MemoryType {min; _} ->
    trace ("Memory size " ^ Int32.to_string min);
    vm.memsize <- Int32.to_int min) (List.map (fun a -> a.it.mtype) m.memories);
  trace ("Segments: " ^ string_of_int (List.length m.data));
  let set_byte loc v =
    let mem = get_memory vm.memory loc in
    memop mem v (Int64.of_int (loc-(loc/8)*8)) (Some Memory.Mem8);
    let a, b = Byteutil.Decode.mini_memory mem in
    vm.memory.(loc/8) <- a;
    vm.memory.(loc/8+1) <- b in
  let init (dta:bytes Ast.segment) =
    let offset = value_to_int (Eval.eval_const instance dta.it.offset) in
    let sz = Bytes.length dta.it.init in
    for i = 0 to sz-1 do
      set_byte (offset+i) (I32 (Int32.of_int (Char.code (Bytes.get dta.it.init i))))
    done in 
  List.iter init m.data;
  ()

let setup_calltable vm m instance f_resolve =
  let open Ast in
  let open Source in
  let ftab, ttab = make_tables m in
  let init (dta:var list Ast.segment) =
    let offset = value_to_int (Eval.eval_const instance dta.it.offset) in
    List.iteri (fun i el ->
      let f_num = Int32.to_int el.it in
      vm.calltable.(offset+i) <- Hashtbl.find f_resolve f_num;
      let func = Byteutil.ftype_hash (Hashtbl.find ftab el.it) in
      trace ("Call table at " ^ string_of_int (offset+i) ^ ": function " ^ string_of_int f_num ^ " type " ^ Int64.to_string func);
      vm.calltable_types.(offset+i) <- func) dta.it.init in
  List.iter init m.elems;
  ()

let handle_ptr regs ptr = function
 | StackRegSub -> ptr - value_to_int regs.reg1
 | StackReg -> value_to_int regs.reg1
 | StackReg2 -> value_to_int regs.reg2
 | StackReg3 -> value_to_int regs.reg3
 | StackInc -> ptr + 1
 | StackDec2 -> ptr - 2
 | StackDec -> ptr - 1
 | StackNop -> ptr
 | StackDecImmed -> ptr - 1 - value_to_int regs.ireg

let load r2 r3 ty sz loc =
  let open Byteutil in
  let mem = mini_memory_v r2 r3 in
  trace ("LOADING " ^ w256_to_string (get_value r2) ^ " & " ^ Byteutil.w256_to_string (get_value r3));
  trace ("Get memory: " ^ w256_to_string (Memory.to_bytes mem));
  let addr = Int64.of_int (loc-(loc/8)*8) in
  ( match sz with
  | None -> Memory.load mem addr 0l ty
  | Some (sz, ext) -> Memory.load_packed sz ext mem addr 0l ty )

let handle_alu r1 r2 r3 ireg = function
 | FixMemory (ty, sz) -> load r2 r3 ty sz (value_to_int r1+value_to_int ireg)
 | Min ->
   let v = min (value_to_int r1) (value_to_int r2) in
   trace ("min " ^ string_of_int v);
   i v
 | Convert op -> Eval_numeric.eval_cvtop op r1
 | Unary op -> Eval_numeric.eval_unop op r1
 | Test op -> value_of_bool (Eval_numeric.eval_testop op r1)
 | Binary op -> Eval_numeric.eval_binop op r1 r2
 | Compare op -> value_of_bool (Eval_numeric.eval_relop op r1 r2)
 | Trap -> raise VmTrap
 | Nop -> r1
 | CheckJump ->
   trace ("check jump " ^ string_of_value r2 ^ " jump to " ^ string_of_value r1 ^ " or " ^ string_of_value r3);
   if value_bool r2 then r1 else i (value_to_int r3)
 | CheckJumpForward -> i (value_to_int r2 + value_to_int r1)
 | HandleBrkReturn -> i (value_to_int r2 + value_to_int r1 - 1)

open Ast

let get_code = function
 | NOP -> noop
 | UNREACHABLE -> {noop with alu_code=Trap}
 | JUMP x -> {noop with immed=i x; read_reg1 = Immed; pc_ch=StackReg}
 | JUMPI x -> {noop with immed=i x; read_reg1 = Immed; read_reg2 = StackIn0; read_reg3 = ReadPc; alu_code = CheckJump; pc_ch=StackReg; stack_ch=StackDec}
 | JUMPFORWARD -> {noop with read_reg1 = StackIn0; read_reg2 = ReadPc; alu_code = CheckJumpForward; pc_ch=StackReg; stack_ch=StackDec}
 | CALL x -> {noop with immed=i x; read_reg1=Immed; read_reg2 = ReadPc; write1 = (Reg2, CallOut); call_ch = StackInc; pc_ch=StackReg}
 | CALLI x -> {noop with immed=I64 x; read_reg1=ReadPc; read_reg2=StackIn0; read_reg3=TableIn; pc_ch=StackReg3; write1 = (Reg2, CallOut); call_ch = StackInc}
 | LABEL _ -> raise VmError (* these should have been processed away *)
 | PUSHBRK x -> {noop with immed=i x; read_reg1 = Immed; read_reg2 = ReadStackPtr; write1 = (Reg1, BreakLocOut); write2 = (Reg2, BreakStackOut); break_ch=StackInc}
 | PUSHBRKRETURN x ->
   {noop with immed=i x; read_reg1 = StackIn0; read_reg2 = ReadStackPtr; read_reg3 = Immed; alu_code = HandleBrkReturn;
              write1 = (Reg3, BreakLocOut); write2 = (Reg1, BreakStackOut); break_ch=StackInc; stack_ch = StackDec}
 | POPBRK -> {noop with break_ch=StackDec}
 | BREAK x -> {noop with immed=i x; read_reg1=Immed; read_reg2=BreakLocInReg; read_reg3=BreakStackInReg; break_ch=StackDecImmed; stack_ch=StackReg3; pc_ch=StackReg2}
 | RETURN -> {noop with read_reg1=CallIn; call_ch=StackDec; pc_ch=StackReg}
 (* IReg + Reg1: memory address *)
 | LOAD x -> {noop with immed=I32 x.offset; read_reg1=StackIn0; read_reg2=MemoryIn1; read_reg3=MemoryIn2; alu_code=FixMemory (x.ty, x.sz); write1=(Reg1, StackOut1)}
 | STORE x -> {noop with immed=I32 x.offset; read_reg1=StackIn1; read_reg2=StackIn0; write1=(Reg2, MemoryOut1 (x.ty,x.sz)); write2=(Reg2, MemoryOut2 (x.ty,x.sz)); stack_ch=StackDec2}
 | DROP -> {noop with stack_ch=StackDec}
 | DUP x -> {noop with immed=i x; read_reg1=Immed; read_reg2=StackInReg; write1=(Reg2, StackOut0); stack_ch=StackInc}
 | SWAP x -> {noop with immed=i x; read_reg1=Immed; read_reg2=StackIn0; write1=(Reg2, StackOutReg1)}
 | LOADGLOBAL x -> {noop with immed=i x; read_reg1=Immed; read_reg2=GlobalIn; write1=(Reg2, StackOut0); stack_ch=StackInc}
 | STOREGLOBAL x -> {noop with immed=i x; read_reg1=Immed; read_reg2=StackIn0; write1=(Reg2, GlobalOut)}
 | CURMEM -> {noop with stack_ch=StackInc; read_reg2 = MemsizeIn; write1=(Reg2, StackOut0)}
 | GROW -> {noop with read_reg2=MemsizeIn; read_reg3 = StackIn0; mem_ch=true; stack_ch=StackDec}
 | PUSH lit -> {noop with immed=lit; read_reg1=Immed; stack_ch=StackInc; write1=(Reg1, StackOut0)}
 | CONV op -> {noop with read_reg1=StackIn0; write1=(Reg1, StackOut1); alu_code=Convert op}
 | UNA op -> {noop with read_reg1=StackIn0; write1=(Reg1, StackOut1); alu_code=Unary op}
 | TEST op -> {noop with read_reg1=StackIn0; write1=(Reg1, StackOut1); alu_code=Test op}
 | BIN op -> {noop with read_reg1=StackIn1; read_reg2=StackIn0; write1=(Reg1, StackOut2); alu_code=Binary op; stack_ch=StackDec}
 | CMP op -> {noop with read_reg1=StackIn1; read_reg2=StackIn0; write1=(Reg1, StackOut2); alu_code=Compare op; stack_ch=StackDec}
 | POPI1 x -> {noop with immed=i x; read_reg1=Immed; read_reg2=StackIn0; alu_code=Min; write1=(Reg1, StackOut1)}
 | POPI2 x -> {noop with immed=i x; read_reg1=Immed; read_reg2=StackIn0; read_reg3=StackInReg2; write1=(Reg3, StackOutReg1); stack_ch=StackRegSub}
 | BREAKTABLE -> {noop with read_reg1=StackIn0; read_reg2=BreakLocInReg; read_reg3=BreakStackInReg; break_ch=StackDec; stack_ch=StackReg3; pc_ch=StackReg2}

let micro_step vm =
  let open Values in
  (* fetch code *)
  let op = get_code vm.code.(vm.pc) in
  (* init registers *)
  let regs = {reg1=i 0; reg2=i 0; reg3=i 0; ireg=op.immed} in
  (* read registers *)
  regs.reg1 <- read_register vm regs op.read_reg1;
  trace ("read R1 " ^ string_of_value regs.reg1);
  regs.reg2 <- read_register vm regs op.read_reg2;
  trace ("read R2 " ^ string_of_value regs.reg2);
  regs.reg3 <- read_register vm regs op.read_reg3;
  trace ("read R3 " ^ string_of_value regs.reg3);
  (* ALU *)
  regs.reg1 <- handle_alu regs.reg1 regs.reg2 regs.reg3 regs.ireg op.alu_code;
  (* Write registers *)
  let w1 = get_register regs (fst op.write1) in
  trace ("write 1: " ^ string_of_value w1);
  write_register vm regs w1 (snd op.write1);
  let w2 = get_register regs (fst op.write2) in
  trace ("write 2: " ^ string_of_value w2);
  write_register vm regs w2 (snd op.write2);
  (* update pointers *)
  trace "update pointers";
  vm.pc <- handle_ptr regs vm.pc op.pc_ch;
  vm.break_ptr <- handle_ptr regs vm.break_ptr op.break_ch;
  vm.stack_ptr <- handle_ptr regs vm.stack_ptr op.stack_ch;
  vm.call_ptr <- handle_ptr regs vm.call_ptr op.call_ch;
  if op.mem_ch then vm.memsize <- vm.memsize + value_to_int regs.reg1

let vm_step vm = match vm.code.(vm.pc) with
 | NOP -> inc_pc vm
 | UNREACHABLE -> raise VmTrap
 | JUMP x ->
   vm.pc <- x
 | JUMPI x ->
   vm.pc <- (if value_bool (vm.stack.(vm.stack_ptr-1)) then x else vm.pc + 1);
   vm.stack_ptr <- vm.stack_ptr - 1
 | JUMPFORWARD ->
   vm.pc <- vm.pc + 1 + value_to_int vm.stack.(vm.stack_ptr-1);
   vm.stack_ptr <- vm.stack_ptr - 1
 | POPI1 x ->
   inc_pc vm;
   let idx = value_to_int vm.stack.(vm.stack_ptr-1) in
   vm.stack.(vm.stack_ptr-1) <- i (if idx < 0 || idx >= x then x else idx)
 | CALL x ->
   (* vm.call_stack.(vm.call_ptr) <- (vm.pc, vm.stack_ptr, vm.break_ptr);  I now guess that it won't need these *)
   vm.call_stack.(vm.call_ptr) <- vm.pc+1;
   vm.call_ptr <- vm.call_ptr + 1;
   vm.pc <- x
 | CALLI x ->
   let addr = value_to_int vm.stack.(vm.stack_ptr-1) in
   vm.stack_ptr <- vm.stack_ptr - 1;
   vm.call_stack.(vm.call_ptr) <- vm.pc+1;
   vm.call_ptr <- vm.call_ptr + 1;
   vm.pc <- vm.calltable.(addr)
 | LABEL _ -> raise VmError (* these should have been processed away *)
 | PUSHBRK x ->
   inc_pc vm;
   vm.break_stack.(vm.break_ptr) <- (x, vm.stack_ptr);
   vm.break_ptr <- vm.break_ptr + 1
 | PUSHBRKRETURN x ->
   inc_pc vm;
   vm.break_stack.(vm.break_ptr) <- (x, vm.stack_ptr + value_to_int vm.stack.(vm.stack_ptr-1) - 1);
   vm.break_ptr <- vm.break_ptr + 1;
   vm.stack_ptr <- vm.stack_ptr - 1
 | POPBRK ->
   inc_pc vm;
   vm.break_ptr <- vm.break_ptr - 1
 | BREAK x ->
   let loc, sptr = vm.break_stack.(vm.break_ptr-1-x) in
   vm.break_ptr <- vm.break_ptr - 1 - x;
   vm.stack_ptr <- sptr;
   vm.pc <- loc
 | RETURN ->
   vm.pc <- vm.call_stack.(vm.call_ptr-1);
   vm.call_ptr <- vm.call_ptr - 1
 | LOAD x ->
   inc_pc vm;
   let loc = value_to_int vm.stack.(vm.stack_ptr-1) + Int32.to_int x.offset in
   let a = vm.memory.(loc/8) in
   let b = vm.memory.(loc/8+1) in
   vm.stack.(vm.stack_ptr-1) <- load (I64 a) (I64 b) x.ty x.sz loc
 | STORE x ->
   let open Byteutil in
   inc_pc vm;
   let loc = value_to_int vm.stack.(vm.stack_ptr-2) + Int32.to_int x.offset in
   let mem = get_memory vm.memory loc in
   let v = vm.stack.(vm.stack_ptr-1) in
   memop mem v (Int64.of_int (loc-(loc/8)*8)) x.sz;
   let a, b = Byteutil.Decode.mini_memory mem in
   vm.memory.(loc/8) <- a;
   vm.memory.(loc/8+1) <- b;
   trace ("STORING " ^ Byteutil.w256_to_string (get_value (I64 a)) ^ " & " ^ Byteutil.w256_to_string (get_value (I64 b)));
   vm.stack_ptr <- vm.stack_ptr - 2
 | DROP ->
   inc_pc vm;
   vm.stack_ptr <- vm.stack_ptr - 1
 | DUP x ->
   inc_pc vm;
   vm.stack.(vm.stack_ptr) <- vm.stack.(vm.stack_ptr-x);
   vm.stack_ptr <- vm.stack_ptr + 1
 | SWAP x ->
   inc_pc vm;
   vm.stack.(vm.stack_ptr-x) <- vm.stack.(vm.stack_ptr-1)
 | LOADGLOBAL x ->
   inc_pc vm;
   vm.stack.(vm.stack_ptr) <- vm.globals.(x);
   vm.stack_ptr <- vm.stack_ptr + 1
 | STOREGLOBAL x ->
   inc_pc vm;
   vm.globals.(x) <- vm.stack.(vm.stack_ptr)
 | CURMEM ->
   inc_pc vm;
   vm.stack.(vm.stack_ptr) <- I32 (Int32.of_int vm.memsize);
   vm.stack_ptr <- vm.stack_ptr + 1
 | GROW ->
   inc_pc vm;
   vm.memsize <- vm.memsize + value_to_int vm.stack.(vm.stack_ptr-1);
   vm.stack_ptr <- vm.stack_ptr - 1
 | POPI2 x ->
   inc_pc vm;
   let idx = value_to_int vm.stack.(vm.stack_ptr-1) in
   vm.stack.(vm.stack_ptr-x-1) <- vm.stack.(vm.stack_ptr-idx-1);
   vm.stack_ptr <- vm.stack_ptr - x
 | BREAKTABLE ->
   let pos = value_to_int (vm.stack.(vm.stack_ptr-1)) in
   let loc, sptr = vm.break_stack.(vm.break_ptr-pos) in
   vm.break_ptr <- vm.break_ptr - 1;
   vm.stack_ptr <- sptr;
   vm.pc <- loc
 | PUSH lit ->
   inc_pc vm;
   vm.stack.(vm.stack_ptr) <- lit;
   vm.stack_ptr <- vm.stack_ptr + 1
 | CONV op ->
   inc_pc vm;
   vm.stack.(vm.stack_ptr-1) <- Eval_numeric.eval_cvtop op vm.stack.(vm.stack_ptr-1)
 | UNA op ->
   inc_pc vm;
   vm.stack.(vm.stack_ptr-1) <- Eval_numeric.eval_unop op vm.stack.(vm.stack_ptr-1)
 | TEST op ->
   inc_pc vm;
   vm.stack.(vm.stack_ptr-1) <- value_of_bool (Eval_numeric.eval_testop op vm.stack.(vm.stack_ptr-1))
 | BIN op ->
   inc_pc vm;
   vm.stack.(vm.stack_ptr-2) <- Eval_numeric.eval_binop op vm.stack.(vm.stack_ptr-2) vm.stack.(vm.stack_ptr-1);
   vm.stack_ptr <- vm.stack_ptr - 1
 | CMP op ->
   inc_pc vm;
   vm.stack.(vm.stack_ptr-2) <- value_of_bool (Eval_numeric.eval_relop op vm.stack.(vm.stack_ptr-2) vm.stack.(vm.stack_ptr-1));
   vm.stack_ptr <- vm.stack_ptr - 1

open Types

let type_size = function
 | I32Type -> 4
 | F32Type -> 4
 | I64Type -> 8
 | F64Type -> 8

let size_size = function
 | Memory.Mem8 -> 1
 | Memory.Mem16 -> 2
 | Memory.Mem32 -> 4

let load_memory_limit addr (op:'a memop) =
  let x = value_to_int addr + Int32.to_int op.offset in
  match op.sz with
  | None -> x - 1 + type_size op.ty
  | Some (sz,_) -> x - 1 + size_size sz

let store_memory_limit addr (op:'a memop) =
  let x = value_to_int addr + Int32.to_int op.offset in
  match op.sz with
  | None -> x - 1 + type_size op.ty
  | Some sz -> x - 1 + size_size sz

let test_errors vm = match vm.code.(vm.pc) with
 | PUSH _ | DUP _ -> if Array.length vm.stack <= vm.stack_ptr then raise (Eval.Exhaustion (Source.no_region, "call stack exhausted"))
 | PUSHBRK _ | PUSHBRKRETURN _ -> if Array.length vm.break_stack <= vm.break_ptr then raise (Eval.Exhaustion (Source.no_region, "call stack exhausted"))
 | CALL _ -> if Array.length vm.call_stack <= vm.call_ptr then raise (Eval.Exhaustion (Source.no_region, "call stack exhausted"))
 | CALLI x ->
   let addr = value_to_int vm.stack.(vm.stack_ptr-1) in
   let len = Array.length vm.calltable in
   if addr > len then raise (Eval.Trap (Source.no_region, "undefined element")) else
   if addr < 0 then raise (Eval.Trap (Source.no_region, "undefined element")) else
   if vm.calltable.(addr) = -1 then raise (Eval.Trap (Source.no_region, "undefined element")) else
   if vm.calltable_types.(addr) <> x then begin
     trace ("At address " ^ string_of_int addr);
     trace ("Expected " ^ Int64.to_string x);
     trace ("Was " ^ Int64.to_string vm.calltable_types.(addr));
     raise (Eval.Trap (Source.no_region, "indirect call signature mismatch"))
   end else
   if Array.length vm.call_stack <= vm.call_ptr then raise (Eval.Exhaustion (Source.no_region, "call stack exhausted"))
 | LOAD op ->
    if load_memory_limit vm.stack.(vm.stack_ptr-1) op >= vm.memsize*64*1024 then raise (Eval.Trap (Source.no_region, "out of bounds memory access"))
    else if value_to_int vm.stack.(vm.stack_ptr-1) >= vm.memsize*64*1024 then raise (Eval.Trap (Source.no_region, "out of bounds memory access"))
    else if Int32.to_int op.offset < 0 then raise (Eval.Trap (Source.no_region, "out of bounds memory access"))
 | STORE op ->
    if store_memory_limit vm.stack.(vm.stack_ptr-2) op >= vm.memsize*64*1024 then raise (Eval.Trap (Source.no_region, "out of bounds memory access"))
    else if value_to_int vm.stack.(vm.stack_ptr-2) >= vm.memsize*64*1024 then raise (Eval.Trap (Source.no_region, "out of bounds memory access"))
    else if Int32.to_int op.offset < 0 then raise (Eval.Trap (Source.no_region, "out of bounds memory access"))
 | _ -> ()

let trace_step vm = match vm.code.(vm.pc) with
 | NOP -> "NOP"
 | UNREACHABLE -> "UNREACHABLE"
 | JUMP x -> "JUMP"
 | JUMPI x ->
   let x = vm.stack.(vm.stack_ptr-1) in
   "JUMPI " ^ (if value_bool x then " jump" else " no jump") ^ " " ^ string_of_value x
 | JUMPFORWARD -> "JUMPFORWARD " ^ string_of_value vm.stack.(vm.stack_ptr-1)
 | CALL x -> "CALL " ^ string_of_int x
 | LABEL _ -> "LABEL ???"
 | PUSHBRK x -> "PUSHBRK"
 | PUSHBRKRETURN x -> "PUSHBRKRETURN stack: " ^ string_of_int (vm.stack_ptr + value_to_int vm.stack.(vm.stack_ptr-1) - 1)
 | POPBRK -> "POPBRK"
 | BREAK x -> "BREAK " ^ string_of_int x
 | RETURN -> "RETURN"
 | LOAD x -> "LOAD from " ^ string_of_value vm.stack.(vm.stack_ptr-1)
 | STORE x -> "STORE " ^ string_of_value vm.stack.(vm.stack_ptr-1) ^ " to " ^ string_of_value vm.stack.(vm.stack_ptr-2)
 | DROP -> "DROP"
 | DUP x -> "DUP" ^ string_of_int x ^ ": " ^ string_of_value vm.stack.(vm.stack_ptr-x)
 | SWAP x -> "SWAP " ^ string_of_int x
 | LOADGLOBAL x -> "LOADGLOBAL"
 | STOREGLOBAL x -> "STOREGLOBAL"
 | CURMEM -> "CURMEM"
 | GROW -> "GROW"
 | POPI1 x -> "POPI1"
 | POPI2 x -> "POPI2"
 | BREAKTABLE -> "BREAKTABLE"
 | PUSH lit -> "PUSH " ^ string_of_value lit
 | CONV op -> "CONV"
 | UNA op -> "UNA"
 | TEST op -> "TEST"
 | BIN op -> "BIN " ^ string_of_value vm.stack.(vm.stack_ptr-2) ^ " " ^ string_of_value vm.stack.(vm.stack_ptr-1)
 | CMP op -> "CMP " ^ string_of_value vm.stack.(vm.stack_ptr-2) ^ " " ^ string_of_value vm.stack.(vm.stack_ptr-1)
 | CALLI x -> "CALLI"

let stack_to_string vm = 
  let res = ref "" in
  for i = 0 to vm.stack_ptr - 1 do
    res := !res ^ " ; " ^ string_of_value vm.stack.(i)
  done;
  !res


