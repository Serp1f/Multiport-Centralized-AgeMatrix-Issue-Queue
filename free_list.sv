// 需要支持bypass
module free_list #(
    parameter   DEPTH = 16,
    parameter   ALLPORT_NUM = 2,     //  申请空闲entry的端口数
    parameter   RELPORT_NUM = 3     //  释放空闲entry的端口数
) (
    input   clk,
    input   rstn,

    input   i_allocate_req,
    input   [$clog2(ALLPORT_NUM+1)-1:0]    i_allocate_num,
    output  logic o_allocate_grant,
    output  logic [ALLPORT_NUM-1:0][$clog2(DEPTH)-1:0]    o_allocate_entry,

    input   i_release,
    input   [$clog2(RELPORT_NUM+1)-1:0]   i_release_num,
    input   [RELPORT_NUM-1:0][$clog2(DEPTH)-1:0]    i_release_entry
);

    logic   allocate;
    logic   [$clog2(DEPTH):0]   free_slots;     // 空闲的entry数
    logic   [$clog2(DEPTH):0]   wr_ptr;     
    logic   [$clog2(DEPTH):0]   rd_ptr;
    logic   [$clog2(DEPTH):0]   wr_ptr_next;
    logic   [$clog2(DEPTH):0]   rd_ptr_next;
    logic   [DEPTH-1:0][$clog2(DEPTH)-1:0]  mem;

    logic   [$clog2(DEPTH)*RELPORT_NUM-1:0] release_entry_flatten;
    always_comb begin
        for(int k=0;k<RELPORT_NUM;k=k+1) begin
            release_entry_flatten[k*$clog2(DEPTH)+:$clog2(DEPTH)] = i_release_entry[k];
        end
    end

//============================== pointer ==============================//

    always_ff @(posedge clk) begin
        if(~rstn)
            free_slots <= DEPTH;
        else if(i_release | (i_allocate_req && o_allocate_grant)) begin
            free_slots <= free_slots + ({$clog2(RELPORT_NUM+1){i_release}} & i_release_num) - ({$clog2(ALLPORT_NUM+1){i_allocate_req}} & i_allocate_num);
        end
    end

    // 先开始就是写满的状态
    always_ff @(posedge clk) begin
        if(~rstn) begin
            wr_ptr <= {1'b1,$clog2(DEPTH)'(0)};
        end
        else if(i_release) begin
            wr_ptr <= wr_ptr_next;
        end
    end
    assign  wr_ptr_next = wr_ptr + ({$clog2(RELPORT_NUM+1){i_release}} & i_release_num);

    always_ff @(posedge clk) begin 
        if(~rstn) begin
            rd_ptr <= 'd0;
        end
        else if(i_allocate_req && o_allocate_grant) begin
            rd_ptr <= rd_ptr_next;
        end
    end
    assign  rd_ptr_next = rd_ptr + ({$clog2(ALLPORT_NUM+1){i_allocate_req}} & i_allocate_num);
    // 非空的条件，标志位相同时读指针低于写指针，标志位不同时写指针低于读指针
    assign  o_allocate_grant = rd_ptr_next[$clog2(DEPTH)] == wr_ptr_next[$clog2(DEPTH)] ? rd_ptr_next[$clog2(DEPTH)-1:0] <= wr_ptr_next[$clog2(DEPTH)-1:0] : rd_ptr_next[$clog2(DEPTH)-1:0] >= wr_ptr_next[$clog2(DEPTH)-1:0];

//================================ memory =============================//

    logic   [DEPTH-1:0][RELPORT_NUM-1:0]        wr_entry_match;
    logic   [DEPTH-1:0][$clog2(DEPTH):0]        wr_ptr_tmp;

    always_comb begin
        for(int i=0;i<DEPTH;i=i+1) begin
            for(int j=0;j<RELPORT_NUM;j=j+1) begin
                wr_ptr_tmp[i] = wr_ptr + j;
                if(i_release)
                    wr_entry_match[i][j] = (i == wr_ptr_tmp[i][$clog2(DEPTH)-1:0]) && (j < i_release_num);
                else 
                    wr_entry_match[i][j] = 1'b0;
            end
        end
    end

    generate
        for(genvar i=0;i<DEPTH;i=i+1) begin: genblk_mem

            logic   [$clog2(DEPTH)-1:0]     wr_data;

            mux_one_hot #(RELPORT_NUM,$clog2(DEPTH)) u_wr_data_mux (
                .mux_in(release_entry_flatten),
                .sel(wr_entry_match[i]),
                .mux_out(wr_data)
            );

            always_ff @(posedge clk) begin
                if(~rstn) 
                    mem[i] <= i;
                else if(i_release && |wr_entry_match[i]) 
                    mem[i] <= wr_data;
            end
        end
    endgenerate

//=============================== output =============================//
    // 当fifo非空，可以分配entry
    logic   [ALLPORT_NUM-1:0][$clog2(DEPTH)-1:0]    rd_data;
    logic   [ALLPORT_NUM-1:0][$clog2(DEPTH):0]      rd_ptr_tmp;
    always_comb begin
        for(int i=0;i<ALLPORT_NUM;i=i+1) begin
            rd_ptr_tmp[i] = rd_ptr + i;
            rd_data[i] = mem[rd_ptr_tmp[i][$clog2(DEPTH)-1:0]]; 
        end
    end

// bypass逻辑，如果free list中的空闲entry数目少于需要分配的，但是空闲entry数目+释放的entry数目大于 需要分配的，则bypass释放的entry到分配的entry
    logic  [ALLPORT_NUM-1:0]  bypass_sel;   // 0: 选择free_list中的数据，1：选择bypass inport的数据
    logic  [ALLPORT_NUM-1:0][$clog2(ALLPORT_NUM)-1:0]  bypass_inport_sel;    // 当bypass_sel[i] == 1时，选择哪个inport的数据
    
    always_comb begin
        for(int i=0;i<ALLPORT_NUM;i=i+1) begin
            if(i < free_slots) begin    // free_list中的entry足够分配
                bypass_sel[i] = 1'b0;
                bypass_inport_sel[i] = 'd0;
            end
            else if(i < (free_slots + ({$clog2(RELPORT_NUM){i_release}} & i_release_num))) begin // free_list+inport中的entry足够分配
                bypass_sel[i] = 1'b1;
                bypass_inport_sel[i] = i - free_slots;
            end
            else begin// entry不够分配
                bypass_sel[i] = 1'b0;
                bypass_inport_sel[i] = 'd0;
            end
        end
    end

    always_comb begin
        for(int i=0;i<ALLPORT_NUM;i=i+1) begin
            o_allocate_entry[i] = (bypass_sel) ? i_release_entry[bypass_inport_sel[i]] : rd_data[i];
        end
    end

endmodule