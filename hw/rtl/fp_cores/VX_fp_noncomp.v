`include "VX_define.vh"

module VX_fp_noncomp #( 
    parameter TAGW = 1,
    parameter LANES = 1
) (
	input wire clk,
	input wire reset,   

    output wire ready_in,
    input wire  valid_in,

    input wire [TAGW-1:0] tag_in,
	
    input wire [`FPU_BITS-1:0] op,
    input wire [`FRM_BITS-1:0] frm,

    input wire [LANES-1:0][31:0]  dataa,
    input wire [LANES-1:0][31:0]  datab,
    output wire [LANES-1:0][31:0] result, 

    output wire has_fflags,
    output fflags_t [LANES-1:0] fflags,

    output wire [TAGW-1:0] tag_out,

    input wire  ready_out,
    output wire valid_out
);  
    localparam  NEG_INF     = 32'h00000001,
                NEG_NORM    = 32'h00000002,
                NEG_SUBNORM = 32'h00000004,
                NEG_ZERO    = 32'h00000008,
                POS_ZERO    = 32'h00000010,
                POS_SUBNORM = 32'h00000020,
                POS_NORM    = 32'h00000040,
                POS_INF     = 32'h00000080,
                SIG_NAN     = 32'h00000100,
                QUT_NAN     = 32'h00000200;

    reg [`FPU_BITS-1:0] op_r;
    reg [`FRM_BITS-1:0] frm_r;

    reg [LANES-1:0][31:0]  dataa_r;
    reg [LANES-1:0][31:0]  datab_r;

    reg [LANES-1:0]       a_sign, b_sign;
    reg [LANES-1:0][7:0]  a_exponent, b_exponent;
    reg [LANES-1:0][22:0] a_mantissa, b_mantissa;
    fp_type_t [LANES-1:0]  a_type, b_type;
    reg [LANES-1:0] a_smaller, ab_equal;

    reg [LANES-1:0][31:0] fclass_mask;  // generate a 10-bit mask for integer reg
    reg [LANES-1:0][31:0] fminmax_res;  // result of fmin/fmax
    reg [LANES-1:0][31:0] fsgnj_res;    // result of sign injection
    reg [LANES-1:0][31:0] fcmp_res;     // result of comparison
    reg [LANES-1:0][ 4:0] fcmp_excp;    // exception of comparison

    wire stall = ~ready_out && valid_out;

    // Setup
    for (genvar i = 0; i < LANES; i++) begin
        wire tmp_a_sign            = dataa[i][31]; 
        wire [7:0] tmp_a_exponent  = dataa[i][30:23];
        wire [22:0] tmp_a_mantissa = dataa[i][22:0];

        wire tmp_b_sign            = datab[i][31]; 
        wire [7:0] tmp_b_exponent  = datab[i][30:23];
        wire [22:0] tmp_b_mantissa = datab[i][22:0];

        fp_type_t tmp_a_type, tmp_b_type;

        VX_fp_type fp_type_a (
            .exponent(tmp_a_exponent[i]),
            .mantissa(tmp_a_mantissa[i]),
            .o_type(tmp_a_type[i])
        );

        VX_fp_type fp_type_b (
            .exponent(tmp_b_exponent[i]),
            .mantissa(tmp_b_mantissa[i]),
            .o_type(tmp_b_type[i])
        );

        wire tmp_a_smaller = (dataa[i] < datab[i]) ^ (tmp_a_sign || tmp_b_sign);
        wire tmp_ab_equal  = (dataa[i] == datab[i]) | (tmp_a_type[4] & tmp_b_type[4]);

        always @(posedge clk) begin
            if (~stall) begin
                a_sign[i]     <= tmp_a_sign;
                b_sign[i]     <= tmp_b_sign;
                a_exponent[i] <= tmp_a_exponent;
                b_exponent[i] <= tmp_b_exponent;
                a_mantissa[i] <= tmp_a_mantissa;
                b_mantissa[i] <= tmp_b_mantissa;
                a_type[i]     <= tmp_a_type;
                b_type[i]     <= tmp_b_type;
                a_smaller[i]  <= tmp_a_smaller;
                ab_equal[i]   <= tmp_ab_equal;
            end
        end 
    end   

    always @(posedge clk) begin
        if (~stall) begin
            op_r    <= op;
            frm_r   <= frm;
            dataa_r <= dataa;
            datab_r <= datab;
        end
    end 

    // FCLASS
    for (genvar i = 0; i < LANES; i++) begin
        always @(*) begin 
            if (a_type[i].is_normal) begin
                fclass_mask[i] = a_sign[i] ? NEG_NORM : POS_NORM;
            end 
            else if (a_type[i].is_inf) begin
                fclass_mask[i] = a_sign[i] ? NEG_INF : POS_INF;
            end 
            else if (a_type[i].is_zero) begin
                fclass_mask[i] = a_sign[i] ? NEG_ZERO : POS_ZERO;
            end 
            else if (a_type[i].is_subnormal) begin
                fclass_mask[i] = a_sign[i] ? NEG_SUBNORM : POS_SUBNORM;
            end 
            else if (a_type[i].is_nan) begin
                fclass_mask[i] = {22'h0, a_type[i].is_quiet, a_type[i].is_signaling, 8'h0};
            end 
            else begin                     
                fclass_mask[i] = QUT_NAN;
            end
        end
    end

    // Min/Max
    for (genvar i = 0; i < LANES; i++) begin
        always @(*) begin
            if (a_type[i].is_nan && b_type[i].is_nan)
                fminmax_res[i] = {1'b0, 8'hff, 1'b1, 22'd0}; // canonical qNaN
            else if (a_type[i].is_nan) 
                fminmax_res[i] = datab_r[i];
            else if (b_type[i].is_nan) 
                fminmax_res[i] = dataa_r[i];
            else begin 
                case (op_r) // use LSB to distinguish MIN and MAX
                    `FPU_MIN: fminmax_res[i] = a_smaller[i] ? dataa_r[i] : datab_r[i];
                    `FPU_MAX: fminmax_res[i] = a_smaller[i] ? datab_r[i] : dataa_r[i];
                    default:  fminmax_res[i] = 32'hdeadbeaf;  // don't care value
                endcase
            end
        end
    end

    // Sign Injection
    for (genvar i = 0; i < LANES; i++) begin
        always @(*) begin
            case (op_r)
                `FPU_SGNJ:  fsgnj_res[i] = { b_sign[i], a_exponent[i], a_mantissa[i]};
                `FPU_SGNJN: fsgnj_res[i] = {~b_sign[i], a_exponent[i], a_mantissa[i]};
                `FPU_SGNJX: fsgnj_res[i] = { a_sign[i] ^ b_sign[i], a_exponent[i], a_mantissa[i]};
                default: fsgnj_res[i] = 32'hdeadbeaf;  // don't care value
            endcase
        end
    end

    // Comparison    
    for (genvar i = 0; i < LANES; i++) begin
        always @(*) begin
            case (frm_r)
                `FRM_RNE: begin
                    if (a_type[i].is_nan || b_type[i].is_nan) begin
                        fcmp_res[i]  = 32'h0;        // result is 0 when either operand is NaN
                        fcmp_excp[i] = {1'b1, 4'h0}; // raise NV flag when either operand is NaN
                    end
                    else begin
                        fcmp_res[i] = {31'h0, (a_smaller[i] | ab_equal[i])};
                        fcmp_excp[i] = 5'h0;
                    end
                end
                `FRM_RTZ: begin 
                    if (a_type[i].is_nan || b_type[i].is_nan) begin
                        fcmp_res[i]  = 32'h0;        // result is 0 when either operand is NaN
                        fcmp_excp[i] = {1'b1, 4'h0}; // raise NV flag when either operand is NaN
                    end
                    else begin
                        fcmp_res[i] = {31'h0, (a_smaller[i] & ~ab_equal[i])};
                        fcmp_excp[i] = 5'h0;
                    end                    
                end
                `FRM_RDN: begin
                    if (a_type[i].is_nan || b_type[i].is_nan) begin
                        fcmp_res[i]  = 32'h0;        // result is 0 when either operand is NaN
                        // ** FEQS only raise NV flag when either operand is signaling NaN
                        fcmp_excp[i] = {(a_type[i].is_signaling | b_type[i].is_signaling), 4'h0};
                    end
                    else begin
                        fcmp_res[i] = {31'h0, ab_equal[i]};
                        fcmp_excp[i] = 5'h0;
                    end
                end
                default: begin
                    fcmp_res[i] = 32'hdeadbeaf;  // don't care value
                    fcmp_excp[i] = 5'h0;                        
                end
            endcase
        end
    end

    // outputs

    reg tmp_valid;
    reg tmp_has_fflags;
    fflags_t [LANES-1:0] tmp_fflags;
    reg [LANES-1:0][31:0] tmp_result;

    always @(*) begin        
        case (op_r)
            `FPU_SGNJ:  tmp_has_fflags = 0;
            `FPU_SGNJN: tmp_has_fflags = 0;
            `FPU_SGNJX: tmp_has_fflags = 0;
            `FPU_MVXW:  tmp_has_fflags = 0;
            `FPU_MVWX:  tmp_has_fflags = 0;
            `FPU_CLASS: tmp_has_fflags = 0;
            default:    tmp_has_fflags = 1;
        endcase
    end   

    for (genvar i = 0; i < LANES; i++) begin
        always @(*) begin
            tmp_valid = 1'b1;
            case (op_r)
                `FPU_CLASS: begin
                    tmp_result[i] = fclass_mask[i];
                    {tmp_fflags[i].NV, tmp_fflags[i].DZ, tmp_fflags[i].OF, tmp_fflags[i].UF, tmp_fflags[i].NX} = 5'h0;
                end                
                `FPU_MVXW,`FPU_MVWX: begin                    
                    tmp_result[i] = dataa[i];
                    {tmp_fflags[i].NV, tmp_fflags[i].DZ, tmp_fflags[i].OF, tmp_fflags[i].UF, tmp_fflags[i].NX} = 5'h0;
                end
                `FPU_MIN,`FPU_MAX: begin                     
                    tmp_result[i] = fminmax_res[i];
                    {tmp_fflags[i].NV, tmp_fflags[i].DZ, tmp_fflags[i].OF, tmp_fflags[i].UF, tmp_fflags[i].NX} = {a_type[i][0] | b_type[i][0], 4'h0};
                end
                `FPU_SGNJ,`FPU_SGNJN,`FPU_SGNJX: begin
                    tmp_result[i] = fsgnj_res[i];
                    {tmp_fflags[i].NV, tmp_fflags[i].DZ, tmp_fflags[i].OF, tmp_fflags[i].UF, tmp_fflags[i].NX} = 5'h0;
                end
                `FPU_CMP: begin 
                    tmp_result[i] = fcmp_res[i];
                    {tmp_fflags[i].NV, tmp_fflags[i].DZ, tmp_fflags[i].OF, tmp_fflags[i].UF, tmp_fflags[i].NX} = fcmp_excp[i];
                end                
                default: begin                      
                    tmp_result[i] = 32'hdeadbeaf;
                    {tmp_fflags[i].NV, tmp_fflags[i].DZ, tmp_fflags[i].OF, tmp_fflags[i].UF, tmp_fflags[i].NX} = 5'h0;
                    tmp_valid = 1'b0;
                end
            endcase
        end
    end

    VX_generic_register #(
        .N(1 + TAGW + (LANES * 32) + 1 + (LANES * `FFG_BITS))
    ) nc_reg (
        .clk   (clk),
        .reset (reset),
        .stall (stall),
        .flush (1'b0),
        .in    ({tmp_valid, tag_in,  tmp_result, tmp_has_fflags, tmp_fflags}),
        .out   ({valid_out, tag_out, result,     has_fflags,     fflags})
    );

    assign ready_in = ~stall;

endmodule