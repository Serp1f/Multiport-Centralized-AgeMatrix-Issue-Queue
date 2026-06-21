// ============================================================================
// Testbench for Multi-Port Issue Queue
// ============================================================================
`timescale 1ns / 1ns

module tb_issue_queue #(
    // ----- Configurable Parameters -----
    parameter DEPTH        = 16,
    parameter REG_WIDTH    = 5,
    parameter INPORT_NUM   = 4,
    parameter WKUP_NUM     = 3,            // Must be >= OUTPORT_NUM
    parameter OUTPORT_NUM  = 3,
    parameter bit          RAND_LATENCY = 1,    //latency from outport to wakeup port 1: random latency 0: fixed latency
    parameter int          FIXED_LATENCY = 2,
    parameter int          MIN_LATENCY   = 1,
    parameter int          MAX_LATENCY   = 4,
    parameter int          TEST_MODE = 3,   // 0: smoke basic, 1: multiport test 2: wakeup test 3: random test
    parameter int          INIT_MIN_REG_READY_NUM = 4,
    parameter int          INIT_MAX_REG_READY_NUM = 8,
    parameter int          GLOBAL_SEED = 114514
) ();
    localparam int random_run_req_num = 100;
    localparam FU_ID_W = $clog2(OUTPORT_NUM);

    // ---------- Signals ----------
    logic                           clk, rstn;
    logic [INPORT_NUM-1:0]          i_push_req;
    logic                           o_push_grant;
    logic [INPORT_NUM-1:0][FU_ID_W-1:0] i_push_fu_id;
    logic [INPORT_NUM-1:0][REG_WIDTH-1:0] i_push_srcL, i_push_srcR, i_push_dst;
    logic [INPORT_NUM-1:0]          i_push_srcL_valid, i_push_srcL_ready;
    logic [INPORT_NUM-1:0]          i_push_srcR_valid, i_push_srcR_ready;
    logic [WKUP_NUM-1:0]            i_wakeup;
    logic [WKUP_NUM-1:0][REG_WIDTH-1:0] i_wakeup_src;
    logic [OUTPORT_NUM-1:0]         o_pop_req, i_pop_grant;
    logic [OUTPORT_NUM-1:0][REG_WIDTH-1:0] o_pop_dst, o_pop_srcL, o_pop_srcR;
    logic [OUTPORT_NUM-1:0]         o_pop_srcL_valid, o_pop_srcR_valid;

    // ---------- DUT Instantiation ---------
    issue_queue #(
        .DEPTH      (DEPTH),
        .REG_WIDTH  (REG_WIDTH),
        .INPORT_NUM (INPORT_NUM),
        .WKUP_NUM   (WKUP_NUM),
        .OUTPORT_NUM(OUTPORT_NUM)
    ) dut (
        .clk              (clk),
        .rstn             (rstn),
        .i_push_req       (i_push_req),
        .o_push_grant     (o_push_grant),
        .i_push_fu_id     (i_push_fu_id),
        .i_push_srcL      (i_push_srcL),
        .i_push_srcL_valid(i_push_srcL_valid),
        .i_push_srcL_ready(i_push_srcL_ready),
        .i_push_srcR      (i_push_srcR),
        .i_push_srcR_valid(i_push_srcR_valid),
        .i_push_srcR_ready(i_push_srcR_ready),
        .i_push_dst       (i_push_dst),
        .i_wakeup         (i_wakeup),
        .i_wakeup_src     (i_wakeup_src),
        .o_pop_req        (o_pop_req),
        .i_pop_grant      (i_pop_grant),
        .o_pop_dst        (o_pop_dst),
        .o_pop_srcL       (o_pop_srcL),
        .o_pop_srcL_valid (o_pop_srcL_valid),
        .o_pop_srcR       (o_pop_srcR),
        .o_pop_srcR_valid (o_pop_srcR_valid)
    );

    // ---------- Golden Model Class ----------
    class golden_model;
        typedef struct packed {
            logic                   valid;
            logic [FU_ID_W-1:0]     fu_id;
            logic [REG_WIDTH-1:0]   dst;
            logic [REG_WIDTH-1:0]   srcL, srcR;
            logic                   srcL_valid, srcL_ready;
            logic                   srcR_valid, srcR_ready;
        } queue_entry_t;

        queue_entry_t   queue[DEPTH];
        bit             hold_active [OUTPORT_NUM];
        queue_entry_t   hold_entry  [OUTPORT_NUM];

        logic                       push_grant;
        logic [OUTPORT_NUM-1:0]     pop_req;
        logic [OUTPORT_NUM-1:0][REG_WIDTH-1:0] pop_dst, pop_srcL, pop_srcR;
        logic [OUTPORT_NUM-1:0]     pop_srcL_valid, pop_srcR_valid;

        function new();
            reset();
        endfunction

        function void reset();
            for (int i=0; i<DEPTH; i++) queue[i] = '0;
            for (int p=0; p<OUTPORT_NUM; p++) begin
                hold_active[p] = 1'b0;
                hold_entry[p]  = '0;
            end
            push_grant = '1; pop_req = '0;
            pop_dst = '0; pop_srcL = '0; pop_srcR = '0;
            pop_srcL_valid = '0; pop_srcR_valid = '0;
        endfunction

        function bit is_reg_in_fifo(
            input   [REG_WIDTH-1:0]     reg_id
        );
            foreach(queue[i]) begin
                if(queue[i].srcL == reg_id || queue[i].srcR == reg_id)
                    return  1;
            end
            return 0;

        endfunction

        function void process_cycle(
            input logic [INPORT_NUM-1:0]                push_req,
            input logic [INPORT_NUM-1:0][FU_ID_W-1:0]   push_fu_id,
            input logic [INPORT_NUM-1:0][REG_WIDTH-1:0] push_srcL, push_srcR, push_dst,
            input logic [INPORT_NUM-1:0]                push_srcL_valid, push_srcL_ready,
            input logic [INPORT_NUM-1:0]                push_srcR_valid, push_srcR_ready,
            input logic [WKUP_NUM-1:0]                  wakeup,
            input logic [WKUP_NUM-1:0][REG_WIDTH-1:0]   wakeup_src,
            input logic [OUTPORT_NUM-1:0]               pop_grant
        );

            int i, p, port, w;
            queue_entry_t temp_q[$];
            int wp;
            int free_slots;
            int pushcnt;

            // 1. POP
            for (p=0; p<OUTPORT_NUM; p++) begin
                if (hold_active[p] && pop_grant[p]) begin
                    for (i=0; i<DEPTH; i++) begin
                        if (queue[i].valid && queue[i].fu_id == FU_ID_W'(p) &&
                            queue[i].dst == hold_entry[p].dst) begin
                            queue[i].valid = 1'b0;
                            $info("outport: %d pop request grant, pop entry %d",p,i);
                            break;
                        end
                    end
                    hold_active[p] = 1'b0;

                end
            end

            // Compress
            for (i=0; i<DEPTH; i++)
                if (queue[i].valid) temp_q.push_back(queue[i]);
            wp = temp_q.size();
            for (i=0; i<DEPTH; i++)
                queue[i] = (i < wp) ? temp_q[i] : '0;

            // 2. PUSH
            free_slots = DEPTH - wp;
            pushcnt = $countones(push_req);
            push_grant = (pushcnt <= free_slots);
            if(pushcnt > 0)
                $info("now push %d request, and free slots is %d, so push_grant is %b",pushcnt,free_slots,push_grant);
            if (push_grant && pushcnt > 0) begin
                $info("begin to push data");
                for (port=0; port<INPORT_NUM; port++) begin
                    if (push_req[port]) begin
                        queue[wp].valid      = 1'b1;
                        queue[wp].fu_id      = push_fu_id[port];
                        queue[wp].dst        = push_dst[port];
                        queue[wp].srcL       = push_srcL[port];
                        queue[wp].srcL_valid = push_srcL_valid[port];
                        queue[wp].srcL_ready = push_srcL_ready[port];
                        queue[wp].srcR       = push_srcR[port];
                        queue[wp].srcR_valid = push_srcR_valid[port];
                        queue[wp].srcR_ready = push_srcR_ready[port];
                        $info("inport %d push request in entry %d",port,wp);
                        wp++;
                    end
                end
            end

            // 3. WAKEUP
            for (w=0; w<WKUP_NUM; w++) begin
                if (wakeup[w]) begin
                    for (i=0; i<DEPTH; i++) begin
                        if (queue[i].valid) begin
                            if (queue[i].srcL_valid && !queue[i].srcL_ready &&
                                queue[i].srcL == wakeup_src[w])  begin
                                queue[i].srcL_ready = 1'b1;
                                $info("wakeup port %d, src %h(hex) match witch entry %d' srcL, this entry's dst is %h",w,wakeup_src[w],i,queue[i].dst);
                                end

                            if (queue[i].srcR_valid && !queue[i].srcR_ready &&
                                queue[i].srcR == wakeup_src[w]) begin
                                queue[i].srcR_ready = 1'b1;
                                $info("wakeup port %d, src %h(hex) match witch entry %d' srcR, this entry's dst is %h",w,wakeup_src[w],i,queue[i].dst);
                                end
                        end
                    end
                end
            end

            // 4. ISSUE REQUEST
            pop_req = '0;
            for (p=0; p<OUTPORT_NUM; p++) begin
                for (i=0; i<DEPTH; i++) begin
                    if (queue[i].valid && queue[i].fu_id == FU_ID_W'(p) &&
                        (!queue[i].srcL_valid || queue[i].srcL_ready) &&
                        (!queue[i].srcR_valid || queue[i].srcR_ready)) begin
                        hold_active[p] = 1'b1;
                        hold_entry[p]  = queue[i];
                        pop_req[p]     = 1'b1;
                        $info("In outport %d, a request is ready to issue, entry %d, dst %h(hex)",p,i,queue[i].dst);
                        break;
                        end
                    end
                // if (!hold_active[p]) begin
                //     for (i=0; i<DEPTH; i++) begin
                //         if (queue[i].valid && queue[i].fu_id == FU_ID_W'(p) &&
                //             (!queue[i].srcL_valid || queue[i].srcL_ready) &&
                //             (!queue[i].srcR_valid || queue[i].srcR_ready)) begin
                //             hold_active[p] = 1'b1;
                //             hold_entry[p]  = queue[i];
                //             pop_req[p]     = 1'b1;
                //             $info("new ready request detected, entry %d, outport %d, dst %h(hex)",i,p,queue[i].dst);
                //             break;

                //         end
                //     end
                // end else begin
                //     // 还需要检测是不是有最老的已经更新
                //     pop_req[p]     = 1'b1;

                //     $info("last pop req is not grant,still ask for grant");
                // end
            end

            // Output data
            for (p=0; p<OUTPORT_NUM; p++) begin
                if (hold_active[p]) begin
                    pop_dst[p]        = hold_entry[p].dst;
                    pop_srcL[p]       = hold_entry[p].srcL;
                    pop_srcL_valid[p] = hold_entry[p].srcL_valid;
                    pop_srcR[p]       = hold_entry[p].srcR;
                    pop_srcR_valid[p] = hold_entry[p].srcR_valid;
                end else begin
                    pop_dst[p]        = '0;
                    pop_srcL[p]       = '0;
                    pop_srcL_valid[p] = '0;
                    pop_srcR[p]       = '0;
                    pop_srcR_valid[p] = '0;
                end
            end
        endfunction
    endclass

    // ---------- Wakeup Delay Queue Class ----------
    class wakeup_delay_queue;
        typedef struct {
            logic [REG_WIDTH-1:0] reg_id;
            int                   remaining;
        } item_t;

        local item_t fifo[$];

        logic [WKUP_NUM-1:0]                    wakeup;
        logic [WKUP_NUM-1:0][REG_WIDTH-1:0]     wakeup_src;

        function new();
            wakeup     = '0;
            wakeup_src = '0;
        endfunction

        function void reset();
            fifo.delete();
            wakeup     = '0;
            wakeup_src = '0;
        endfunction

        function void process_cycle(
            input logic [OUTPORT_NUM-1:0]               pop_req,
            input logic [OUTPORT_NUM-1:0]               pop_grant,
            input logic [OUTPORT_NUM-1:0][REG_WIDTH-1:0]pop_dst
        );
            int p, i, sent, removed;
            item_t item;
            item_t new_fifo[$];

            // 1. Push new items
            for (p=0; p<OUTPORT_NUM; p++) begin
                if (pop_req[p] && pop_grant[p]) begin
                    item.reg_id = pop_dst[p];
                    item.remaining = RAND_LATENCY ?
                                     $urandom_range(MIN_LATENCY, MAX_LATENCY) :
                                     FIXED_LATENCY;
                    $info("outport %d pop a request, dst is %d, it will finish in %d cycle",p,item.reg_id,item.remaining);
                    fifo.push_back(item);
                end
            end

            // 2. Generate wakeup signals
            wakeup     = '0;
            wakeup_src = '0;
            sent = 0;
            for (i=0; i<fifo.size() && sent<OUTPORT_NUM; i++) begin
                if (fifo[i].remaining == 0) begin
                    $info("reg_id %d finish, it's sent to wakeup port %d",fifo[i].reg_id,fifo[i].remaining);
                    wakeup[sent]     = 1'b1;
                    wakeup_src[sent] = fifo[i].reg_id;
                    sent++;
                end
            end

            // 3. Update fifo
            removed = 0;
            foreach (fifo[i]) begin
                if (fifo[i].remaining == 0 && removed < OUTPORT_NUM) begin
                    removed++;
                    continue;
                end else begin
                    if (fifo[i].remaining > 0)
                        fifo[i].remaining--;
                    new_fifo.push_back(fifo[i]);
                end
            end
            fifo = new_fifo;
        endfunction

        function bit is_reg_in_fifo(
            input   [REG_WIDTH-1:0]     reg_id
        );
            foreach(fifo[i]) begin
                if(fifo[i].reg_id == reg_id)
                    return  1;
            end
            return 0;

        endfunction
    endclass

    // ---------- Checker Class ----------
    class my_checker;
        function void check_cycle(
            input logic                               dut_push_grant,
            input logic                               gm_push_grant,
            input logic [OUTPORT_NUM-1:0]             dut_pop_req,
            input logic [OUTPORT_NUM-1:0]             gm_pop_req,
            input logic [OUTPORT_NUM-1:0]             pop_grant,
            input logic [OUTPORT_NUM-1:0][REG_WIDTH-1:0] dut_pop_dst, gm_pop_dst,
            input logic [OUTPORT_NUM-1:0][REG_WIDTH-1:0] dut_pop_srcL, gm_pop_srcL,
            input logic [OUTPORT_NUM-1:0][REG_WIDTH-1:0] dut_pop_srcR, gm_pop_srcR,
            input logic [OUTPORT_NUM-1:0]             dut_pop_srcL_valid, gm_pop_srcL_valid,
            input logic [OUTPORT_NUM-1:0]             dut_pop_srcR_valid, gm_pop_srcR_valid
        );
            int p;
            if (dut_push_grant !== gm_push_grant) begin
                $error("Mismatch o_push_grant: DUT=%b, GOLD=%b", dut_push_grant, gm_push_grant);
            end
            if (dut_pop_req !== gm_pop_req) begin
                $error("Mismatch o_pop_req: DUT=%b, GOLD=%b", dut_pop_req, gm_pop_req);
            end
            for (p=0; p<OUTPORT_NUM; p++) begin
                if (dut_pop_req[p] && pop_grant[p]) begin
                    if (dut_pop_dst[p] !== gm_pop_dst[p])
                        $error("Port %0h dst mismatch: DUT=%0h, GOLD=%0h", p, dut_pop_dst[p], gm_pop_dst[p]);
                    if (dut_pop_srcL[p] !== gm_pop_srcL[p])
                        $error("Port %0h srcL mismatch", p);
                    if (dut_pop_srcL_valid[p] !== gm_pop_srcL_valid[p])
                        $error("Port %0d srcL_valid mismatch", p);
                    if (dut_pop_srcR[p] !== gm_pop_srcR[p])
                        $error("Port %0h srcR mismatch", p);
                    if (dut_pop_srcR_valid[p] !== gm_pop_srcR_valid[p])
                        $error("Port %0d srcR_valid mismatch", p);
                end
            end
        endfunction
    endclass

    // ---------- Instances ----------
    golden_model          gm = new();
    wakeup_delay_queue    wdq = new();
    my_checker            chk = new();

    // logic gm_push_grant;
    // logic [OUTPORT_NUM-1:0] gm_pop_req;
    // logic [OUTPORT_NUM-1:0][REG_WIDTH-1:0] gm_pop_dst;
    // logic [OUTPORT_NUM-1:0][REG_WIDTH-1:0] gm_pop_srcL;
    // logic [OUTPORT_NUM-1:0][REG_WIDTH-1:0] gm_pop_srcR;
    // logic [OUTPORT_NUM-1:0] gm_pop_srcL_valid;
    // logic [OUTPORT_NUM-1:0] gm_pop_srcR_valid;

    logic gm_push_grant_r;
    logic [OUTPORT_NUM-1:0] gm_pop_req_r;
    logic [OUTPORT_NUM-1:0][REG_WIDTH-1:0] gm_pop_dst_r;
    logic [OUTPORT_NUM-1:0][REG_WIDTH-1:0] gm_pop_srcL_r;
    logic [OUTPORT_NUM-1:0][REG_WIDTH-1:0] gm_pop_srcR_r;
    logic [OUTPORT_NUM-1:0] gm_pop_srcL_valid_r;
    logic [OUTPORT_NUM-1:0] gm_pop_srcR_valid_r;

    logic [WKUP_NUM-1:0]                wdq_wakeup_r;
    logic [WKUP_NUM-1:0][REG_WIDTH-1:0] wdq_wakeup_src_r;

    always_comb begin
        i_wakeup     = wdq_wakeup_r;
        i_wakeup_src = wdq_wakeup_src_r;
    end

    // ---------- Grant override for directed tests ----------
    bit                 grant_override_enable;
    logic [OUTPORT_NUM-1:0] grant_override_val;

    // ---------- Stimulus Generator ----------
    bit [(1<<REG_WIDTH)-1:0]    ready_reg_state;
    bit [(1<<REG_WIDTH)-1:0]    queue_reg_state;
    bit [(1<<REG_WIDTH)-1:0]    wakeup_reg_state;

    // port src bundle class
class src_bundle;
    // 使用 rand 关键字声明随机变量
    rand bit [$clog2(OUTPORT_NUM)-1:0]  fu_id;
    rand bit [REG_WIDTH-1:0]  srcL;      
    rand bit [REG_WIDTH-1:0]  srcR;      
    bit srcL_valid;
    bit srcR_valid; 
    bit srcL_ready;
    bit srcR_ready; 
    rand bit [REG_WIDTH-1:0]  dst;
    bit [(1<<REG_WIDTH)-1:0]  reg_state_shadow;

    bit srcL_enable;
    bit srcR_enable;

    // function void pre_randomize();
    //     reg_state_shadow = ready_reg_state;
    //     $info("reg_state_shadow initial");
    // endfunction

    
    // constraint valid_constrain {
    //     solve srcR before srcL;

    //     ((ready_reg_state[srcL] || gm.is_reg_in_fifo(srcL) || wdq.is_reg_in_fifo(srcL))) | 
    //     ((ready_reg_state[srcR] || gm.is_reg_in_fifo(srcR) || wdq.is_reg_in_fifo(srcR))) == 1'b1;
    // }
    constraint fu_id_constrain {
        fu_id < OUTPORT_NUM;
    }

    constraint reg_id_constrain {
        solve srcL,srcR before dst;
        dst != srcR;
        dst != srcL;
    }

    function void post_randomize();
        // srcL
        if(srcL_enable) begin
            case ({ready_reg_state[srcL],queue_reg_state[srcL],wakeup_reg_state[srcL]})
                3'b000: begin srcL_valid = 1'b0;srcL_ready = 1'b1; end // 该寄存器未被使用过
                3'b100: begin srcL_valid = 1'b1;srcL_ready = 1'b1; end // 寄存器已经准备好
                3'b010: begin srcL_valid = 1'b1;srcL_ready = 1'b0; end // 寄存器在issue_queue中，等待发射
                3'b001: begin srcL_valid = 1'b1;srcL_ready = 1'b0; end // 寄存器在fu中执行
                default:  begin srcL_valid = 1'b0;srcL_ready = 1'b1; end // 非法状态，认为寄存器无效
            endcase
        end
        else begin
            srcL_valid = 1'b0;
            srcL_ready = 1'b1;
        end
        // srcR 
        if(srcR_enable) begin
            case ({ready_reg_state[srcR],queue_reg_state[srcL],wakeup_reg_state[srcL]})
                3'b000: begin srcR_valid = 1'b0;srcR_ready = 1'b1; end // 该寄存器未被使用过
                3'b100: begin srcR_valid = 1'b1;srcR_ready = 1'b1; end // 寄存器已经准备好
                3'b010: begin srcR_valid = 1'b1;srcR_ready = 1'b0; end // 寄存器在issue_queue中，等待发射
                3'b001: begin srcR_valid = 1'b1;srcR_ready = 1'b0; end // 寄存器在fu中执行
                default:  begin srcR_valid = 1'b0;srcR_ready = 1'b1; end // 非法状态，认为寄存器无效
            endcase 
        end 
        else begin
            srcR_valid = 1'b0;
            srcR_ready = 1'b1;
        end
        if(srcL_valid && srcR_valid && srcL == srcR) begin  // 两个寄存器均有效时寄存器不能相等
            srcR_valid = 1'b0;
            srcR_ready = 1'b1;
        end
    endfunction

endclass

class   push_bundle;

    rand bit [INPORT_NUM-1:0]   port_valid;
    rand src_bundle port[0:INPORT_NUM-1];

    constraint  valid_constrain {
        $countones(port_valid) > 0;
    }

    function new();
        for (int i=0;i<INPORT_NUM;i=i+1)
            port[i] = new();

    endfunction

    function void post_randomize();
        for(int i=1;i<INPORT_NUM;i=i+1) begin
            if(port_valid[i]) begin
                for(int j=0;j<i;j=j+1) begin
                    // 如果这个port的dst与之前的相同，则重新生成一个
                    if(port[j].dst == port[i].dst) begin
                        if(port[i].randomize() with { 
                            queue_reg_state[port[i].dst] == 1'b0; 
                            wakeup_reg_state[port[i].dst] == 1'b0;
                            port[i].dst != port[j].dst;
                        }) ;
                        else 
                            $error("can't re-randomize same dst");
                    end
                end
            end
        end

    endfunction

endclass

    initial begin
        i_push_req = '0; i_push_fu_id = '0;
        i_push_srcL = '0; i_push_srcR = '0; i_push_dst = '0;
        i_push_srcL_valid = '0; i_push_srcL_ready = '0;
        i_push_srcR_valid = '0; i_push_srcR_ready = '0;
        @(posedge rstn);
        wait_cycle(2);
        case (TEST_MODE)
            0: smoke_basic();
            1: multiport_test();
            2: wakeup_test();
            3: random_stress();
            default: smoke_basic();
        endcase
        $info("TEST PASSED");
        #100 $finish;
    end

    task automatic send_inst(push_bundle pb);
        for(int i = 0;i<INPORT_NUM;i=i+1) begin
            i_push_req[i] = pb.port_valid[i];
            i_push_fu_id[i] = pb.port[i].fu_id;
            i_push_srcL[i] = pb.port[i].srcL;
            i_push_srcL_valid[i] = pb.port[i].srcL_valid;
            i_push_srcL_ready[i] = pb.port[i].srcL_ready;
            i_push_srcR[i] = pb.port[i].srcR;
            i_push_srcR_valid[i] = pb.port[i].srcR_valid;
            i_push_srcR_ready[i] = pb.port[i].srcR_ready;
            i_push_dst[i] = pb.port[i].dst;
        end
        do begin 
            @(posedge clk); 
            // 如果这一拍没有握手但是唤醒端口的寄存器和输入端口匹配上了，就要做ready的更新
            for(int i=0;i<INPORT_NUM;i=i+1) begin
                for(int j=0;j<WKUP_NUM;j=j+1) begin
                    if(i_push_req[i] && i_wakeup[j] && i_push_srcL[i] == i_wakeup_src[j] && i_push_srcL_valid[i] && ~i_push_srcL_ready[i])
                        i_push_srcL_ready[i] = 1'b1;
                    if(i_push_req[i] && i_wakeup[j] && i_push_srcR[i] == i_wakeup_src[j] && i_push_srcR_valid[i] && ~i_push_srcR_ready[i])
                        i_push_srcR_ready[i] = 1'b1;
                end
            end
        end
        while (!o_push_grant);
        i_push_req = 'd0;
    endtask

    always_ff @(posedge clk) begin
        if(~rstn) begin
            queue_reg_state <= 'd0;
            wakeup_reg_state <= 'd0;
        end
        else begin
            // when i_push_req, clear ready_reg_state, set queue_reg_state
            for(int ip = 0;ip < INPORT_NUM; ip++) begin
                if(i_push_req[ip] && o_push_grant) begin
                    ready_reg_state[i_push_dst[ip]] <= 1'b0;
                    queue_reg_state[i_push_dst[ip]] <= 1'b1;
                end
            end
            // when o_pop, clear queue_reg_state, set wakeup_reg_state
            for(int op = 0;op <OUTPORT_NUM; op++) begin
                if(o_pop_req[op] && i_pop_grant[op]) begin
                    queue_reg_state[o_pop_dst[op]] <= 1'b0;
                    wakeup_reg_state[o_pop_dst[op]] <= 1'b1;
                end
            end
            // when i_wakeup, set ready_reg_state, clear wakeup_reg_state
            for (int wp = 0; wp < WKUP_NUM; wp++) begin
                if (i_wakeup[wp]) begin
                    wakeup_reg_state[i_wakeup_src[wp]] <= 1'b0;
                    ready_reg_state[i_wakeup_src[wp]] <= 1'b1;
                end
            end
        end
    end

    task automatic wait_cycle(int n = 1);
        repeat (n) begin
            @(posedge clk) #1;
        end
    endtask

    task automatic init_reg_state();
        
        assert(std::randomize(ready_reg_state) with { $countones(ready_reg_state) >= INIT_MIN_REG_READY_NUM && $countones(ready_reg_state) <= INIT_MAX_REG_READY_NUM ;})
        else $error("randomize ready_reg_state fail");

    endtask
    
    // ====================================================================
    //                    Test Tasks
    // ====================================================================

    task automatic smoke_basic();
        int dummy;
        push_bundle pb;
        begin
            // initial ready_reg_state
            init_reg_state();
            grant_override_enable = 1'b1;
            grant_override_val    = 'd0;    // don't grant
            wait_cycle(1);
            pb = new();
            pb.srandom(GLOBAL_SEED);   // 指定种子
            // 只从一个口写，只从一个口读
            for(int i=0;i<OUTPORT_NUM;i=i+1) begin
                grant_override_val = 'd0;
                for(int j=0;j<DEPTH;j=j+1) begin
                    pb.port[(j%4)].srcL_enable = 1'b1;
                    pb.port[(j%4)].srcR_enable = 1'b0;
                    if(pb.randomize() with { 
                        pb.port_valid == 1 << (j % 4);
                        pb.port[(j%4)].fu_id == i;
                        local::ready_reg_state[pb.port[(j%4)].srcL] == 1'b1;
                    }) begin
                        send_inst(pb);
                    end
                    else begin
                        $error("fail to randomize push_bundle");
                    end
                    wait_cycle($urandom_range(0,4));
                end
                grant_override_val = 2'b11;
                // Wait enough random_run_req_num for instruction to be popped
                wait_cycle(20);
            end
            $stop(); 
        end
    endtask

    task automatic multiport_test();
        int p;
        push_bundle pb;
        begin
            // initial ready_reg_state
            init_reg_state();
            // grant_override_enable = 1'b1;
            // grant_override_val    = 'd0;    // don't grant
            wait_cycle(1);
            pb = new();
            pb.srandom(GLOBAL_SEED);   // 指定种子
            // 只让srcL有效，srcR无效
            foreach(pb.port[i]) begin
                pb.port[i].srcL_enable = 1'b1;
                pb.port[i].srcR_enable = 1'b0;
            end
            // 执行8次
            for(int i=0;i<8;i=i+1) begin

                if(pb.randomize() with {
                    $countones(pb.port_valid) > 1;
                    foreach(pb.port[i]) {
                        local::ready_reg_state[pb.port[i].srcL] == 1'b1;
                        local::ready_reg_state[pb.port[i].srcR] == 1'b1;
                    }
                }) begin
                    send_inst(pb);
                end
                else begin
                    $error("fail to randomize push_bundle");
                end
                wait_cycle($urandom_range(0,4));
            end

            // Wait enough random_run_req_num for instruction to be popped
            wait_cycle(20);
            $stop();
            // grant_override_enable = 1'b0;
        end
    endtask

    task automatic wakeup_test();
        push_bundle pb;
        begin
            // initial ready_reg_state
            init_reg_state();
            grant_override_enable = 1'b1;
            grant_override_val    = 'd0;    // don't grant
            wait_cycle(1);
            pb = new();
            pb.srandom(GLOBAL_SEED);   // 指定种子
            // 只让srcL有效，srcR无效
            foreach(pb.port[i]) begin
                pb.port[i].srcL_enable = 1'b1;
                pb.port[i].srcR_enable = 1'b0;
            end
            // 先发送两次没有依赖关系，不需要唤醒的指令
            for(int i=0;i<2;i=i+1) begin

                if(pb.randomize() with {
                    $countones(pb.port_valid) == 2;
                    foreach(pb.port[i]) {
                        local::ready_reg_state[pb.port[i].srcL] == 1'b1;
                        local::ready_reg_state[pb.port[i].srcR] == 1'b1;
                    }
                }) begin
                    send_inst(pb);
                end
                else begin
                    $error("fail to randomize push_bundle");
                end
                wait_cycle($urandom_range(0,4));
            end
            // 然后发送有依赖关系，需要唤醒的指令
            for(int i=0;i<3;i=i+1) begin

                if(pb.randomize() with {
                    $countones(pb.port_valid) == 1;
                    foreach(pb.port[i]) {
                        local::queue_reg_state[pb.port[i].srcL] == 1'b1;
                    }
                }) begin
                    send_inst(pb);
                end
                else begin
                    $error("fail to randomize push_bundle");
                end
                wait_cycle($urandom_range(0,4));
            end   
            grant_override_val    = 2'b11;    // 开始给grant
            // Wait enough random_run_req_num for instruction to be popped
            wait_cycle(30);
            $stop();

        end
    endtask

    task automatic random_stress();

        push_bundle pb;
        begin
            // initial ready_reg_state
            init_reg_state();
            wait_cycle(1);
            pb = new();
            pb.srandom(GLOBAL_SEED);   
            foreach(pb.port[i]) begin
                pb.port[i].srcL_enable = 1'b1;
                pb.port[i].srcR_enable = 1'b1;
            end

            for(int i=0;i<random_run_req_num;i=i+1) begin

                if(pb.randomize() with {
                    $countones(pb.port_valid) > 1;
                    foreach(pb.port[i]) {
                        local::ready_reg_state[pb.port[i].srcL] ||
                        local::queue_reg_state[pb.port[i].srcL] ||
                        local::wakeup_reg_state[pb.port[i].srcL] == 1'b1;
                        local::queue_reg_state[pb.port[i].dst] == 1'b0;
                        local::wakeup_reg_state[pb.port[i].dst] == 1'b0;
                    }
                }) begin
                    send_inst(pb);
                end
                else begin
                    $error("fail to randomize push_bundle");
                end
                wait_cycle($urandom_range(0,4));
            end   
            // Wait enough random_run_req_num for instruction to be popped
            wait_cycle(30);
            $stop();
        end
    endtask

    // ---------- Clock and Reset ----------
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end
    initial begin
        rstn = 0;
        #20 rstn = 1;
    end
    initial begin
        i_pop_grant = '0;
        @(posedge rstn);
        forever begin
            @(posedge clk) #1;
            for (int p=0; p<OUTPORT_NUM; p++) begin
                if(grant_override_enable)
                    i_pop_grant[p] = grant_override_val[p];
                else 
                    i_pop_grant[p] = $urandom_range(0,1);

            end
        end
    end

    // ---------- Main Cycle Processing ----------


    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            gm.reset();
            wdq.reset();
            gm_push_grant_r      <= '1;
            gm_pop_req_r         <= '0;
            gm_pop_dst_r         <= '0;
            gm_pop_srcL_r        <= '0;
            gm_pop_srcR_r        <= '0;
            gm_pop_srcL_valid_r  <= '0;
            gm_pop_srcR_valid_r  <= '0;
            wdq_wakeup_r         <= 'd0;
            wdq_wakeup_src_r     <= 'd0;
        end else begin
            gm.process_cycle(
                i_push_req, i_push_fu_id,
                i_push_srcL, i_push_srcR, i_push_dst,
                i_push_srcL_valid, i_push_srcL_ready,
                i_push_srcR_valid, i_push_srcR_ready,
                i_wakeup, i_wakeup_src,
                i_pop_grant
            );
            wdq.process_cycle(o_pop_req, i_pop_grant, o_pop_dst);
            gm_push_grant_r      = gm.push_grant;
            gm_pop_req_r         <= gm.pop_req;
            gm_pop_dst_r         <= gm.pop_dst;
            gm_pop_srcL_r        <= gm.pop_srcL;
            gm_pop_srcR_r        <= gm.pop_srcR;
            gm_pop_srcL_valid_r  <= gm.pop_srcL_valid;
            gm_pop_srcR_valid_r  <= gm.pop_srcR_valid;
            wdq_wakeup_r         <= wdq.wakeup;
            wdq_wakeup_src_r     <= wdq.wakeup_src;
        end
    end

    always_ff @(posedge clk) begin
        if (rstn) begin
            chk.check_cycle(
                o_push_grant, gm_push_grant_r,
                o_pop_req, gm_pop_req_r,
                i_pop_grant,
                o_pop_dst, gm_pop_dst_r,
                o_pop_srcL, gm_pop_srcL_r,
                o_pop_srcR, gm_pop_srcR_r,
                o_pop_srcL_valid, gm_pop_srcL_valid_r,
                o_pop_srcR_valid, gm_pop_srcR_valid_r
            );
        end
    end

endmodule