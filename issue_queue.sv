// 少了dependency管理，如果先后进入的请求srcL或srcR相等，他们有依赖关系，需要管理。
module issue_queue #(
    parameter   DEPTH = 16,
    parameter   REG_WIDTH = 5,
    parameter   INPORT_NUM = 2,     //  指令进入的port个数
    parameter   WKUP_NUM = 4,       //  指令唤醒的port个数
    parameter   OUTPORT_NUM = 3     //  指令输出的port个数，实际上对应fu
) (
    input   clk,
    input   rstn,

// 向发射队列发出写入请求，如果表项不足，则无法写入
// 例如只剩下2个空余表项，但是要写入3个表项，则不能写入
    input   [INPORT_NUM-1:0]                            i_push_req,        // 哪一个端口是有效的
    output                                              o_push_grant,
    input   [INPORT_NUM-1:0][$clog2(OUTPORT_NUM)-1:0]   i_push_fu_id,        //  请求的类型,向哪一个FU发射
    input   [INPORT_NUM-1:0][REG_WIDTH-1:0]             i_push_srcL,
    input   [INPORT_NUM-1:0]                            i_push_srcL_valid,
    input   [INPORT_NUM-1:0]                            i_push_srcL_ready,
    input   [INPORT_NUM-1:0][REG_WIDTH-1:0]             i_push_srcR,
    input   [INPORT_NUM-1:0]                            i_push_srcR_valid,
    input   [INPORT_NUM-1:0]                            i_push_srcR_ready,
    input   [INPORT_NUM-1:0][REG_WIDTH-1:0]             i_push_dst,

    input   [WKUP_NUM-1:0]                              i_wakeup,
    input   [WKUP_NUM-1:0][REG_WIDTH-1:0]               i_wakeup_src,   // 唤醒执行完毕的寄存器

    output  [OUTPORT_NUM-1:0]                   o_pop_req,    // 多种请求，每种请求只能有1个仲裁请求
    input   [OUTPORT_NUM-1:0]                   i_pop_grant,  // 仲裁请求给出，同时也需要弹出数据
    output  [OUTPORT_NUM-1:0][REG_WIDTH-1:0]    o_pop_dst,
    output  [OUTPORT_NUM-1:0][REG_WIDTH-1:0]    o_pop_srcL,
    output  [OUTPORT_NUM-1:0]                   o_pop_srcL_valid,
    output  [OUTPORT_NUM-1:0][REG_WIDTH-1:0]    o_pop_srcR,
    output  [OUTPORT_NUM-1:0]                   o_pop_srcR_valid

);
    localparam  FUID_WIDTH = $clog2(OUTPORT_NUM);
    localparam  IDX_WIDTH = $clog2(DEPTH);
    localparam  MEM_WIDTH = FUID_WIDTH + REG_WIDTH +  1 + 1 + REG_WIDTH + 1 + 1 + REG_WIDTH;
    // 数据在mem按照req_type,srcL(data+valid+ready),srcR,dst排列
    // {fu_id,srcL,srcL_valid,srcL_ready,srcL_dp,srcL_dp_idx,srcR,srcR_valid,srcR_ready}
    localparam  FUID_BASE = 0;
    localparam  SRCL_BASE = FUID_WIDTH;
    localparam  SRCR_BASE = SRCL_BASE + REG_WIDTH + 1 + 1;
    localparam  DST_BASE = SRCR_BASE + REG_WIDTH + 1 + 1;

    logic   pop;  // 有一种请求得到仲裁
    logic   push;
    logic [$clog2(OUTPORT_NUM+1)-1:0]   pop_num;
    logic [$clog2(INPORT_NUM+1)-1:0]    push_num;
    logic [OUTPORT_NUM-1:0]             pop_hs;
    logic [OUTPORT_NUM-1:0]             pop_hs_sorted;
    logic [INPORT_NUM-1:0]              push_hs;
    logic [INPORT_NUM-1:0]              push_hs_sorted;

    logic [INPORT_NUM-1:0][MEM_WIDTH-1:0]   push_data;
    logic [INPORT_NUM-1:0][MEM_WIDTH-1:0]   push_data_sorted;
    logic [INPORT_NUM*MEM_WIDTH-1:0]        push_data_sorted_flatten;

    logic [INPORT_NUM-1:0][$clog2(DEPTH)-1:0]   push_entry;
    logic [OUTPORT_NUM-1:0][$clog2(DEPTH)-1:0]  pop_entry;

    logic [DEPTH-1:0][INPORT_NUM-1:0]       wr_entry_match;
    logic [DEPTH-1:0][OUTPORT_NUM-1:0]      rd_entry_match;
    logic [OUTPORT_NUM-1:0][DEPTH-1:0]      arb_enable;
    logic [OUTPORT_NUM-1:0][$clog2(DEPTH)-1:0]  fu_oldest_entry;

    logic [DEPTH-1:0]   entry_valid;
    logic [DEPTH-1:0][MEM_WIDTH-1:0]    mem;        // 压缩队列保存数据的ram

    logic [INPORT_NUM-1:0][WKUP_NUM-1:0] wakeup_srcL_input_match;
    logic [INPORT_NUM-1:0][WKUP_NUM-1:0] wakeup_srcR_input_match;

    logic [DEPTH-1:0][WKUP_NUM-1:0]    wakeup_srcL_entry_match;   // entry中的srcL与i_wakeup_src能对应  
    logic [DEPTH-1:0][WKUP_NUM-1:0]    wakeup_srcR_entry_match;   // entry中的srcR与i_wakeup_src能对应
    logic [DEPTH-1:0]   entry_srcL_ready_update;
    logic [DEPTH-1:0]   entry_srcR_ready_update;

// ======================= push port =========================//
//  需要将输入的气泡压缩，例如 4'b1010 压缩为 4'b0011, 有效位和数据都需要压缩

    always_comb begin
        for(int i=0;i<INPORT_NUM;i=i+1) begin
            for(int j=0;j<WKUP_NUM;j=j+1) begin
                if(i_push_req[i] && i_wakeup[j]) begin
                    wakeup_srcL_input_match[i][j] = i_push_srcL[i] == i_wakeup_src[j] && i_push_srcL_valid[i];
                    wakeup_srcR_input_match[i][j] = i_push_srcR[i] == i_wakeup_src[j] && i_push_srcR_valid[i];
                end
                else begin
                    wakeup_srcL_input_match[i][j] = 1'b0;
                    wakeup_srcR_input_match[i][j] = 1'b0;
                end
            end
        end
    end

    generate
        for(genvar i=0;i<INPORT_NUM;i=i+1) begin
            assign  push_data[i][DST_BASE+:REG_WIDTH] = i_push_dst[i];
            // 当输入端口与唤醒端口匹配，更新ready
            assign  push_data[i][SRCR_BASE+REG_WIDTH+1] = ~i_push_srcR_valid[i] || i_push_srcR_ready[i] || (|wakeup_srcR_input_match[i]);
            assign  push_data[i][SRCR_BASE+REG_WIDTH] = i_push_srcR_valid[i];
            assign  push_data[i][SRCR_BASE+:REG_WIDTH] = i_push_srcR[i];
            // 当输入端口与唤醒端口匹配，更新ready
            assign  push_data[i][SRCL_BASE+REG_WIDTH+1] = ~i_push_srcL_valid[i] || i_push_srcL_ready[i] || (|wakeup_srcL_input_match[i]);
            assign  push_data[i][SRCL_BASE+REG_WIDTH] = i_push_srcL_valid[i];
            assign  push_data[i][SRCL_BASE+:REG_WIDTH] = i_push_srcL[i];
            assign  push_data[i][FUID_BASE+:FUID_WIDTH] = i_push_fu_id[i];
        end
    endgenerate

    bubble_remove #(INPORT_NUM,MEM_WIDTH) u_push_br
    (
        .mask(push_hs),
        .mask_data(push_data),
        
        .sorted_mask(push_hs_sorted),
        .sorted_mask_data(push_data_sorted)
    );

    always_comb begin
        for(int k=0;k<INPORT_NUM;k=k+1) begin
            push_data_sorted_flatten[k*MEM_WIDTH+:MEM_WIDTH] = push_data_sorted[k];
        end
    end

// ========================= allocate ==========================//
    assign  push_hs = i_push_req & {INPORT_NUM{o_push_grant}};
    assign  push = |push_hs;

    assign  pop_hs = o_pop_req & i_pop_grant;
    assign  pop = |pop_hs;

    vector_sumer #(OUTPORT_NUM) u_pop_num_sumer
    (
        .vec(pop_hs),
        .sum(pop_num)
    );
    
    vector_sumer #(INPORT_NUM) u_push_num_sumer
    (
        .vec(i_push_req),
        .sum(push_num)
    );

    bubble_remove #(OUTPORT_NUM,$clog2(DEPTH)) u_pop_br
    (
        .mask(pop_hs),
        .mask_data(fu_oldest_entry),
        
        .sorted_mask(pop_hs_sorted),
        .sorted_mask_data(pop_entry)
    );

    free_list #(
        .DEPTH(DEPTH),
        .ALLPORT_NUM(INPORT_NUM),
        .RELPORT_NUM(OUTPORT_NUM)
    ) u_free_list (
        .clk(clk),
        .rstn(rstn),
        
        .i_allocate_req(|i_push_req),
        .i_allocate_num(push_num),
        .o_allocate_grant(o_push_grant),
        .o_allocate_entry(push_entry),

        .i_release(pop),
        .i_release_num(pop_num),
        .i_release_entry(pop_entry)
    );

    generate
        for(genvar i=0;i<DEPTH;i=i+1) begin
            always_ff @(posedge clk) begin
                if(~rstn)
                    entry_valid[i] <= 1'b0;
                else if(|wr_entry_match[i])
                    entry_valid[i] <= 1'b1;
                else if(|rd_entry_match[i])
                    entry_valid[i] <= 1'b0;
            end
        end
    endgenerate


// =========================== arbitration ===========================//

    logic [OUTPORT_NUM-1:0][DEPTH-1:0]  tmp_mask;
    always_comb begin
        for(int i=0;i<OUTPORT_NUM;i=i+1) begin
            for(int j=0;j<DEPTH;j=j+1) begin
                if(entry_valid[j])  // entry有效，fu_id == i,并且ready全为高，可以参与仲裁
                    arb_enable[i][j] = (mem[j][FUID_BASE+:FUID_WIDTH] == i) && (mem[j][SRCR_BASE+REG_WIDTH+1] && mem[j][SRCL_BASE+REG_WIDTH+1]);
                else 
                    arb_enable[i][j] = 1'b0;
            end
        end
    end

    age_matrix #(
        .UD_NUM(INPORT_NUM),
        .MK_NUM(OUTPORT_NUM),
        .WAY_NUM(DEPTH)
    )   u_age_matrix (
        .clk(clk),
        .rstn(rstn),
        .i_update(push_hs_sorted),
        .i_way(push_entry),
        .i_enable(arb_enable),
    
        .o_lru_way(fu_oldest_entry)
    );


// ============================================= entry ===============================================//

    // 唤醒检测
    always_comb begin
        for(int k=0;k<WKUP_NUM;k=k+1) begin
            for(int m=0;m<DEPTH;m=m+1) begin
                if(i_wakeup[k] && entry_valid[m]) begin
                    // i_wakeup[i] 并且 i_wakeup的寄存器和mem中的寄存器相等 并且 mem中寄存器有效
                    wakeup_srcL_entry_match[m][k] = (mem[m][SRCL_BASE+:REG_WIDTH] == i_wakeup_src[k]) && mem[m][SRCL_BASE+REG_WIDTH];
                    wakeup_srcR_entry_match[m][k] = (mem[m][SRCR_BASE+:REG_WIDTH] == i_wakeup_src[k]) && mem[m][SRCR_BASE+REG_WIDTH];
                end
                else begin
                    wakeup_srcL_entry_match[m][k] = 1'b0;
                    wakeup_srcR_entry_match[m][k] = 1'b0;
                end
            end
        end
    end

    // 写入位置检测
    always_comb begin
        for(int k=0;k<DEPTH;k=k+1) begin
            for(int m=0;m<INPORT_NUM;m=m+1) begin
                if(push_hs_sorted[m])
                    wr_entry_match[k][m] = push_entry[m] == k;
                else 
                    wr_entry_match[k][m] = 1'b0;
            end
        end
    end

    always_comb begin
        for(int k=0;k<DEPTH;k=k+1) begin
            for(int m=0;m<OUTPORT_NUM;m=m+1) begin
                if(pop_hs_sorted[m])
                    rd_entry_match[k][m] = pop_entry[m] == k;
                else 
                    rd_entry_match[k][m] = 1'b0;
            end
        end
    end

    generate
        for(genvar i=0;i<DEPTH;i=i+1) begin: genblk_mem

            logic [MEM_WIDTH-1:0]   push_data_entry_i;  //  写入的数据
            logic [MEM_WIDTH-1:0]   merge_wr_data;      //  当wakeup时如果寄存器匹配，必须将最新的结果写入

            // 当寄存器和wakeup的寄存器匹配(任意一个）并且 寄存器不是ready的，更新寄存器
            assign  entry_srcL_ready_update[i] = |wakeup_srcL_entry_match[i] && ~mem[i][SRCL_BASE+REG_WIDTH+1];
            assign  entry_srcR_ready_update[i] = |wakeup_srcR_entry_match[i] && ~mem[i][SRCR_BASE+REG_WIDTH+1];

            // 从push_data_flatten中选出与地址匹配的数据，例如i与wr_pos[0]匹配，则选出push_data_flatten[0]作为wr_data
            mux_one_hot #(INPORT_NUM,MEM_WIDTH) u_wr_data_mux (
                .mux_in(push_data_sorted_flatten),
                .sel(wr_entry_match[i]),
                .mux_out(push_data_entry_i)
            );
            
            assign  merge_wr_data = push_data_entry_i;

            always_ff @(posedge clk) begin
                if(~rstn)
                    mem[i] <= {MEM_WIDTH{1'b0}};
                // addr == wr_pos[0,1,...,] 写入数据
                if(push && |wr_entry_match[i])
                    mem[i] <= merge_wr_data;
                else if(entry_srcL_ready_update[i] | entry_srcR_ready_update[i]) begin // srcL match
                    mem[i][SRCL_BASE+REG_WIDTH+1] <= mem[i][SRCL_BASE+REG_WIDTH+1] | entry_srcL_ready_update[i];
                    mem[i][SRCR_BASE+REG_WIDTH+1] <= mem[i][SRCR_BASE+REG_WIDTH+1] | entry_srcR_ready_update[i];
                end
            end
        end

    endgenerate

// ================================= pop port =========================//
    generate
        for(genvar i=0;i<OUTPORT_NUM;i=i+1) begin: genblk_output

            logic   [MEM_WIDTH-1:0]    rd_data_bundle;

            assign  o_pop_req[i] = |arb_enable[i];            
            assign  rd_data_bundle = mem[fu_oldest_entry[i]];
            // srcL
            assign  o_pop_srcL[i] = rd_data_bundle[SRCL_BASE+:REG_WIDTH];  // srcL
            assign  o_pop_srcL_valid[i]  = rd_data_bundle[SRCL_BASE+REG_WIDTH];   // srcL_valid
            // srcR
            assign  o_pop_srcR[i] = rd_data_bundle[SRCR_BASE+:REG_WIDTH];  // srcL
            assign  o_pop_srcR_valid[i]  = rd_data_bundle[SRCR_BASE+REG_WIDTH];   // srcL_valid
            // data
            assign  o_pop_dst[i] = rd_data_bundle[DST_BASE+:REG_WIDTH];
        end
    endgenerate

// ========================== just for debug ===================//
    logic   [DEPTH-1:0][IDX_WIDTH-1:0]  debug_fu_id;
    logic   [DEPTH-1:0][REG_WIDTH-1:0]  debug_dst;
    logic   [DEPTH-1:0][REG_WIDTH-1:0]  debug_srcL;
    logic   [DEPTH-1:0][REG_WIDTH-1:0]  debug_srcR;
    logic   [DEPTH-1:0]                 debug_srcL_valid;
    logic   [DEPTH-1:0]                 debug_srcR_valid;
    logic   [DEPTH-1:0]                 debug_srcL_ready;
    logic   [DEPTH-1:0]                 debug_srcR_ready;

    always_comb begin
        for(int i=0;i<DEPTH;i=i+1) begin
            debug_fu_id[i] = mem[i][FUID_BASE+:FUID_WIDTH];
            debug_dst[i] = mem[i][DST_BASE+:REG_WIDTH];
            debug_srcL[i] = mem[i][SRCL_BASE+:REG_WIDTH];
            debug_srcL_valid[i] = mem[i][SRCL_BASE+REG_WIDTH];
            debug_srcL_ready[i] = mem[i][SRCL_BASE+REG_WIDTH+1];
            debug_srcR[i] = mem[i][SRCR_BASE+:REG_WIDTH];
            debug_srcR_valid[i] = mem[i][SRCR_BASE+REG_WIDTH];
            debug_srcR_ready[i] = mem[i][SRCR_BASE+REG_WIDTH+1];
        end
    end

endmodule