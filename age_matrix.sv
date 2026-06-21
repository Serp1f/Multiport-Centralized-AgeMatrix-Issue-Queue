module age_matrix #(
    parameter   UD_NUM = 3,     // update port num
    parameter   MK_NUM = 3,     // mask port num
    parameter   WAY_NUM = 6
)(
    input   clk,
    input   rstn,

    input   [UD_NUM-1:0]  i_update,
    input   [UD_NUM-1:0][$clog2(WAY_NUM)-1:0]   i_way,
    input   [MK_NUM-1:0][WAY_NUM-1:0]   i_enable,     // 只使能参与仲裁的way

    output  [MK_NUM-1:0][$clog2(WAY_NUM)-1:0]   o_lru_way
);

    logic  [WAY_NUM-1:0][UD_NUM-1:0]    row_match;
    logic  [WAY_NUM-1:0][UD_NUM-1:0]    col_match;
    logic  [WAY_NUM-1:0][WAY_NUM-1:0]   age_matrix;
    logic  [MK_NUM-1:0][WAY_NUM-1:0][WAY_NUM-1:0]   masked_age_matrix;
    logic  [MK_NUM-1:0][WAY_NUM-1:0]    way_oldest;

    always_comb begin
        for(int m=0;m<WAY_NUM;m=m+1) begin
            for(int n=0;n<UD_NUM;n=n+1) begin
               row_match[m][n] = i_update[n] ? i_way[n] == m : 1'b0;
               col_match[m][n] = i_update[n] ? i_way[n] == m : 1'b0;
            end
        end
    end

    generate
        for(genvar i=0;i<WAY_NUM;i=i+1) begin: genblk_row
            for(genvar j=0;j<WAY_NUM;j=j+1) begin: genblk_col
                // age_matrix[i][j] == 1, entry[i] 比 entry[j] 新
                if(j < i)   begin: genblk_flop  // 下三角矩阵，寄存器
                    always_ff @( posedge clk ) begin
                        if(~rstn)
                            age_matrix[i][j] <= 1'b0;
                        else if((|row_match[i]) | (|col_match[j])) begin
                            case ({|row_match[i],|col_match[j]})
                            2'b11:  age_matrix[i][j] <= compare_onehot(row_match[i],col_match[j]) ? 1'b1 : 1'b0;
                            2'b10:  age_matrix[i][j] <= 1'b1;   // 一行的数据置1
                            2'b01:  age_matrix[i][j] <= 1'b0;   // 一列的数据置1
                            default: age_matrix[i][j] <= 1'b0; 
                            endcase
                        end
                    end
                end

                else if(j > i) begin:   genblk_wire // 上三角矩阵，下三角的取反
                    assign  age_matrix[i][j] = ~age_matrix[j][i];
                end
                else begin: genblk_tie0 // 对角线，tie0
                    assign  age_matrix[i][j] = 1'b0;
                end
                
            end
        end
    endgenerate

    always_comb begin
        for(int i=0;i<WAY_NUM;i=i+1) begin
            for(int j=0;j<WAY_NUM;j=j+1) begin
                for(int k=0;k<MK_NUM;k=k+1) begin
                    // 如果entry被保留，则保留该矩阵的值
                    case({i_enable[k][i],i_enable[k][j]})
                    2'b11:  masked_age_matrix[k][i][j] = age_matrix[i][j];
                    2'b10:  masked_age_matrix[k][i][j] = 1'b0;
                    2'b01:  masked_age_matrix[k][i][j] = 1'b0;
                    2'b00:  masked_age_matrix[k][i][j] = 1'b1;
                    endcase
                end
            end
        end
    end

    always_comb begin
        for(int i=0;i<MK_NUM;i=i+1) begin
            for(int j=0;j<WAY_NUM;j=j+1) begin
                // 如果一个entry比所有entry新（也即age_matrix[i]全为0，那么他就是最老的
                way_oldest[i][j] = ~|masked_age_matrix[i][j];
            end
        end
    end

    generate
        for(genvar i=0;i<MK_NUM;i=i+1) begin: genblk_onehot_to_binaray
            onehot_to_binary  #(WAY_NUM)  u_oh2bi
            (
                .onehot(way_oldest[i]),
                .binary(o_lru_way[i])
            );
        end
    endgenerate

    function automatic logic [0:0] compare_onehot(
        input   [UD_NUM-1:0]    onehot_A,
        input   [UD_NUM-1:0]    onehot_B
    );
        logic   [$clog2(UD_NUM)-1:0]    bin_A;
        logic   [$clog2(UD_NUM)-1:0]    bin_B;
        for(int i=0;i<UD_NUM;i=i+1) begin
            if(onehot_A[i])
                bin_A = i;
        end
        for(int i=0;i<UD_NUM;i=i+1) begin
            if(onehot_B[i])
                bin_B = i;
        end
        return bin_A > bin_B;
    endfunction


endmodule