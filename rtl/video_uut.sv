/****************************************************************************
FILENAME     :  video_uut.sv
PROJECT      :  Hack-a-Thon 2026
****************************************************************************/

/*---------------------------------------------------------------------------*/
//------------------------------------------------------------------------------
// Notes:
// - Assumes dvh_sync_i = {D_sync, Vsync, Hsync} per the comment in the repo.
// - Uses vh_blank_i = {Vblank, Hblank}. Active video when both are 0.
// - Keeps the same 1-cycle latency as the original (registers RGB + dvh_sync).
// - This version draws MULTIPLE "Flappy Bird" style pipe obstacles.
//   Each obstacle is two rectangles (top+bottom) with a vertical gap.
// - Pipes move horizontally (to the left) and wrap INDIVIDUALLY.
//   Wrap placement uses (current rightmost pipe) + PIPE_SPACING to avoid
//   clustering and blank gaps.
// - Motion updates once per frame (on vsync rising edge) to avoid tearing.
// - Speed/geometry can be adjusted with localparams below.
// - CHANGE (for Vivado + randomization):
//   * gap_y[] is now REGISTERED state (initialized in reset, updated on wrap)
//   * LFSR added to randomize gap_y[] on wrap (no expensive modulo)
//   * Wrap logic fixed to avoid stacking if multiple pipes wrap in same frame
//------------------------------------------------------------------------------

// IMPORTANT:
// This code intentionally uses 4-state synthesizable types (logic/integer)
// to keep Vivado synthesis happy.

module video_uut (
    input  wire         clk_i           ,// clock
    input  wire         cen_i           ,// clock enable
    input  wire         rst_i           ,// reset
    input  wire         vid_sel_i       ,// select between video sources
    input  wire 		switch1			,
	input  wire 		switch2			,
	input  wire 		switch3			,
	input  wire [23:0]  vid_rgb_i       ,// [23:0] = R[23:16], G[15:8], B[7:0]
    input  wire [1:0]   vh_blank_i      ,// input  video timing signals
    input  wire [2:0]   dvh_sync_i      ,// HDMI timing signals
    output wire [2:0]   dvh_sync_o      ,// HDMI timing signals delayed
    output wire [23:0]  vid_rgb_o        // [23:0] = R[23:16], G[15:8], B[7:0]
); 


    // ----------------------------
    // Bird tunables (autopilot)
    // ----------------------------
	localparam int unsigned SPR_W = 172;
    localparam int unsigned SPR_H = 120;
    localparam int unsigned SPR_PIXELS = SPR_W * SPR_H;
    localparam int unsigned SPR_AW = $clog2(SPR_PIXELS);
	

    localparam integer BIRD_X           = 420;
    localparam integer BIRD_SPEED       = 6;            // px/frame, adjust for smoothness

    (* rom_style = "block" *) logic [23:0] spr_rgb [0:SPR_PIXELS-1];

    initial begin
        $readmemh("bird1.hex", spr_rgb);
    end

    localparam integer GRASS_HEIGHT  = 80;   // pixels from bottom
    localparam integer GROUND_HEIGHT = 40;   // pixels at very bottom

    localparam logic [23:0] GRASS_COLOUR  = 24'h2E_8B_57; // green
    localparam logic [23:0] GROUND_COLOUR = 24'h8B_45_13; // brown
 
    // ----------------------------
    // Tunables (edit these)
    // ----------------------------
    localparam integer FRAME_W       = 1920;
    localparam integer FRAME_H       = 1080;

    localparam integer PIPE_WIDTH    = 90;     // thickness of each pipe (pixels)
    localparam integer GAP_HEIGHT    = 240;    // gap opening (pixels)

    // Increase this to get more pipes on screen (3 or 4 recommended)
    localparam integer NUM_PIPES     = 4;

    // Distance between consecutive pipes (pixels)
    localparam integer PIPE_SPACING  = 520;

    // Base speed in pixels/frame (60 fps -> speed*60 pixels/sec)
    localparam integer PIPE_SPEED_SLOW = 4;
    localparam integer PIPE_SPEED_FAST = 8;

    // Initial gap vertical positions (used only at reset)
    // gap_y is the TOP of the gap.
    localparam integer GAP0_Y = 300;
    localparam integer GAP1_Y = 520;
    localparam integer GAP2_Y = 220;
    localparam integer GAP3_Y = 460;

    // Colors
    localparam logic [23:0] BG_COLOUR   = 24'h87_CE_EB;  // light sky blue
    localparam logic [23:0] PIPE_COLOUR = 24'h30_D0_30;  // green pipes

    // ----------------------------
    // Pipe shading (outline + highlight + body)
    // ----------------------------
    localparam integer PIPE_OUTLINE_W = 2;            // pixels (dark border)
    localparam integer PIPE_HILITE_W  = 4;            // pixels (light strip)
    localparam logic [23:0] PIPE_DARK  = 24'h1F_A0_1F; // darker green
    localparam logic [23:0] PIPE_LIGHT = 24'h6A_F0_6A; // lighter green


    // ----------------------------
    // Random gap tunables (LFSR)
    // ----------------------------
    localparam integer GAP_MARGIN = 80;  // keep gaps away from top/bottom

    // ----------------------------
    // LFSR helpers (Vivado-synthesizable)
    // ----------------------------
    // 16-bit maximal-length LFSR taps: 16,14,13,11
    function automatic logic [15:0] lfsr_next(input logic [15:0] s);
        logic fb;
        begin
            fb = s[15] ^ s[13] ^ s[12] ^ s[10];
            lfsr_next = {s[14:0], fb};
        end
    endfunction

    // Map LFSR state -> valid gap_y (top of gap), avoiding expensive modulo.
    function automatic integer gap_from_lfsr(input logic [15:0] s);
        integer gap_min;
        integer gap_max;
        integer range;
        integer v;
        integer raw;
        begin
            gap_min = GAP_MARGIN;
            gap_max = FRAME_H - GAP_HEIGHT - GAP_MARGIN;

            // If margins make range invalid, fall back to a safe middle position
            if (gap_max <= gap_min) begin
                gap_from_lfsr = (FRAME_H - GAP_HEIGHT) / 2;
            end else begin
                range = (gap_max - gap_min + 1);

                // Use 10 bits: 0..1023
                raw = s[9:0];

                // Fold into [0..range-1] by repeated subtraction (cheap)
                v = raw;
                if (v >= range) v = v - range;
                if (v >= range) v = v - range;
                if (v >= range) v = v - range;

                gap_from_lfsr = gap_min + v;
            end
        end
    endfunction
    // ----------------------------
    // Chroma-key transparency:
    // Only green-dominant pixels are transparent;
    // white/gray/yellow are kept (opaque).
    // ----------------------------
    function automatic logic is_transparent(input logic [23:0] rgb);
        logic [7:0] r, g, b;
        logic [7:0] mx, mn;
        begin
            r = rgb[23:16];
            g = rgb[15:8];
            b = rgb[7:0];

            // max/min of channels
            mx = (r >= g) ? ((r >= b) ? r : b) : ((g >= b) ? g : b);
            mn = (r <= g) ? ((r <= b) ? r : b) : ((g <= b) ? g : b);

            // Keep low saturation (white/gray)
            if ((mx - mn) <= 8'h20)
                is_transparent = 1'b0;
            // Keep yellow (high R & G, low B)
            else if ((r > 8'hA0) && (g > 8'hA0) && (b < 8'h60))
                is_transparent = 1'b0;
            else
                // Otherwise transparent if green is dominant
                is_transparent = (g > r) && (g > b);
        end
    endfunction
    // ----------------------------
    // Bird state
    // ----------------------------
    integer bird_y;          // bird top position (pixels)
    integer bird_target_y;   // target top position (pixels)
    integer next_pipe_idx;   // which pipe we're aiming for
    integer best_pipe_x;     // used to select the nearest upcoming pipe

    // ----------------------------
    // Internal state
    // ----------------------------
    logic [23:0] vid_rgb_d1;
    logic [2:0]  dvh_sync_d1;
    logic game_over;

    // Pixel coordinates within the active picture region
    localparam integer X_BITS = $clog2(FRAME_W);
    localparam integer Y_BITS = $clog2(FRAME_H);
    logic [X_BITS-1:0] x;
    logic [Y_BITS-1:0] y;

    // For edge detection of sync pulses (store previous levels)
    logic hsync_q, vsync_q;

    // Pipe X positions (left edges). Use 4-state integers for Vivado friendliness.
    integer pipe_x [0:NUM_PIPES-1];

    // Gap positions (top of gap) for each pipe (REGISTERED STATE now)
    integer gap_y  [0:NUM_PIPES-1];

    // LFSR state (must never be 0)
    logic [15:0] lfsr;

    // temp array used for safe wrap/rightmost computation (Vivado-friendly)
    integer next_x [0:NUM_PIPES-1];

    // Decode timing bits (per comment): {D_sync, Vsync, Hsync}
    wire vsync = dvh_sync_i[1];
    wire hsync = dvh_sync_i[0];

    // Active picture region: not in blanking
    wire active_vid = (vh_blank_i == 2'b00);

    // Rising edges: 1 for a single clk_i cycle when the sync rises
    wire hsync_rise =  hsync & ~hsync_q;
    wire vsync_rise =  vsync & ~vsync_q;


	// Push button signals
	wire switch1_db;
	wire switch2_db;
	wire switch3_db;
	
	button_debounce debounce1 (
		.clk(clk_i),
		.rst(rst_i),
		.button_in(~switch1),
		.button_out(switch1_db)
	);

	button_debounce debounce2 (
		.clk(clk_i),
		.rst(rst_i),
		.button_in(~switch2),
		.button_out(switch2_db)
	);
	
	button_debounce debounce3 (
		.clk(clk_i),
		.rst(rst_i),
		.button_in(~switch3),
		.button_out(switch3_db)
	);
	
	
	
	logic player_mode;
	
	
	// Reset rising edge detection
	logic switch3_db_q;
	logic game_reset_pulse;

	always_ff @(posedge clk_i or posedge rst_i) begin
		if (rst_i) begin
			switch3_db_q    <= 1'b0;
			game_reset_pulse <= 1'b0;
		end else begin
			switch3_db_q    <= switch3_db;
			game_reset_pulse <= switch3_db & ~switch3_db_q; // rising edge
		end
	end
	
    // Speed select (4-state integer, NOT a wire net)
    integer pipe_speed;

    // ----------------------------
    // Combinational helpers
    // (CHANGE: gap_y[] is NOT assigned here anymore; it's registered state)
    // ----------------------------
    integer i;
    always_comb begin
        // Speed select
        pipe_speed = (vid_sel_i) ? PIPE_SPEED_FAST : PIPE_SPEED_SLOW;
    end

	// ----------------------------
    // Procedural background colour
    // Sky gradient + grass + ground
    // ----------------------------
    logic [23:0] bg_pixel;
	
	always_comb begin
        // Default: sky gradient
        // y = 0 (top) -> light blue
        // y increases -> darker blue
        integer blue_val;

        blue_val = 8'd220 - (integer'(y) >> 3); // darker toward bottom

        if (blue_val < 8'd120)
            blue_val = 8'd120;

        // Sky colour (light → dark blue)
        bg_pixel = {8'd135, 8'd206, blue_val};

        // Grass strip
        if (integer'(y) >= (FRAME_H - GRASS_HEIGHT - GROUND_HEIGHT))
            bg_pixel = GRASS_COLOUR;

        // Ground strip (very bottom)
        if (integer'(y) >= (FRAME_H - GROUND_HEIGHT))
            bg_pixel = GROUND_COLOUR;
    end

    // ----------------------------
    // Pipe shading helpers (captures local x inside the pipe column)
    // ----------------------------
    integer pipe_local_x;       // 0..PIPE_WIDTH-1 for the hit pipe
    logic   pipe_local_x_valid; // 1 when pipe_local_x is valid
    logic [23:0] pipe_pixel;    // final shaded pipe colour for this pixel

    // ----------------------------
    // Pipe hit tests (pure combinational)
    // A pixel hits a pipe if:
    // - X is inside pipe column: pipe_x <= x < pipe_x + PIPE_WIDTH
    // - and Y is outside the gap: y < gap_y OR y >= gap_y + GAP_HEIGHT
    // ----------------------------
    logic pipes_hit;
    logic pipe_in_x;
    logic pipe_in_y;
	
    always_comb begin
        pipes_hit          = 1'b0;
        pipe_local_x       = 0;
        pipe_local_x_valid = 1'b0;

        for (i = 0; i < NUM_PIPES; i = i + 1) begin
            pipe_in_x = (integer'(x) >= pipe_x[i]) && (integer'(x) < (pipe_x[i] + PIPE_WIDTH));
            pipe_in_y = (integer'(y) <  gap_y[i])  || (integer'(y) >= (gap_y[i] + GAP_HEIGHT));

            if (active_vid && pipe_in_x && pipe_in_y) begin
                pipes_hit = 1'b1;

                // Capture local x from the FIRST matching pipe (deterministic)
                if (!pipe_local_x_valid) begin
                    pipe_local_x       = integer'(x) - pipe_x[i];
                    pipe_local_x_valid = 1'b1;
                end
            end
        end
    end

    // ----------------------------
    // Choose shaded pipe colour based on local_x inside the pipe
    // ----------------------------
    always_comb begin
        pipe_pixel = PIPE_COLOUR;

        if (pipes_hit && pipe_local_x_valid) begin
            if ((pipe_local_x < PIPE_OUTLINE_W) ||
                (pipe_local_x >= (PIPE_WIDTH - PIPE_OUTLINE_W))) begin
                pipe_pixel = PIPE_DARK; // outline on both sides
            end else if (pipe_local_x < (PIPE_OUTLINE_W + PIPE_HILITE_W)) begin
                pipe_pixel = PIPE_LIGHT; // highlight strip near left
            end else begin
                pipe_pixel = PIPE_COLOUR; // body
            end
        end
    end



    // Bird pixel hit test (draw a square at fixed X, variable Y)
    // ----------------------------
    // Bird sprite hit test and transparency
    // ----------------------------
    wire in_bird_sprite =
        active_vid &&
        (integer'(x) >= BIRD_X) &&
        (integer'(x) < (BIRD_X + SPR_W)) &&
        (integer'(y) >= bird_y) &&
        (integer'(y) < (bird_y + SPR_H));
    
	
	// sprite-local coordinates (only meaningful when in_bird_sprite=1)
    wire [X_BITS-1:0] spr_x = x - X_BITS'(BIRD_X);
    wire [Y_BITS-1:0] spr_y = y - Y_BITS'(bird_y);

    // row-major address: addr = spr_y*SPR_W + spr_x
    wire [SPR_AW-1:0] spr_addr = SPR_AW'(spr_y * SPR_W + spr_x);

    wire [23:0] spr_pixel = spr_rgb[spr_addr];
    wire spr_opaque = in_bird_sprite && (~is_transparent(spr_pixel));
    wire bird_hit = spr_opaque;

    wire collision = bird_hit && pipes_hit;

    // ----------------------------
    // Sequential logic
    // ----------------------------
    integer rightmost_next;
    integer base_next;

    always_ff @(posedge clk_i) begin
		
		
		if (rst_i || game_reset_pulse) begin
			player_mode <= 1'b0;            // demo mode
		end else if (switch1_db || switch2_db) begin
			player_mode <= 1'b1;            // lock into player mode
		end
		if (rst_i) begin
            // Reset everything to known values so the first frame is stable
            vid_rgb_d1   <= 24'h00_00_00;
            dvh_sync_d1  <= 3'b000;
            x            <= '0;
            y            <= '0;
            hsync_q      <= 1'b0;
            vsync_q      <= 1'b0;
		end	
		
		if(rst_i || game_reset_pulse) begin
            game_over    <= 1'b0;
			
            // Seed LFSR (MUST be non-zero)
            lfsr <= 16'hACE1;

            // Bird init
            bird_y        <= (FRAME_H/2) - (SPR_H/2);
            bird_target_y <= (FRAME_H/2) - (SPR_H/2);
            next_pipe_idx <= 0;
            best_pipe_x   <= 0;

            // Initialize pipes evenly spaced off-screen to the right
            for (i = 0; i < NUM_PIPES; i = i + 1) begin
                pipe_x[i] <= FRAME_W + 200 + (i * PIPE_SPACING);
            end

            // Initialize gaps to your original fixed values (then randomize on wraps)
            gap_y[0] <= GAP0_Y;
            if (NUM_PIPES > 1) gap_y[1] <= GAP1_Y;
            if (NUM_PIPES > 2) gap_y[2] <= GAP2_Y;
            if (NUM_PIPES > 3) gap_y[3] <= GAP3_Y;
            for (i = 4; i < NUM_PIPES; i = i + 1) begin
                gap_y[i] <= GAP0_Y;
            end

        end else begin
            // Track sync levels for edge detection (not gated by cen_i)
            hsync_q <= hsync;
            vsync_q <= vsync;

            if (cen_i) begin
                if (!game_over && collision)
                    game_over <= 1'b1;
                // 1) Update coordinates (x,y)
                if (vsync_rise) begin
                    x <= '0;
                    y <= '0;
                end
                else if (hsync_rise) begin
                    x <= '0;
                    if (integer'(y) != (FRAME_H - 1))
                        y <= y + 1'b1;
                end
                else if (active_vid) begin
                    if (integer'(x) != (FRAME_W - 1))
                        x <= x + 1'b1;
                end

                // 2) Move pipes ONCE PER FRAME (on vsync rising edge)
                //    + Wrap pipes without stacking
                //    + Randomize gap_y[i] using LFSR on each wrap
                if (vsync_rise && !game_over) begin
                    logic [15:0] lfsr_tmp;

                    // Advance LFSR once per frame (keeps randomness evolving even if no wrap)
                    lfsr_tmp = lfsr_next(lfsr);

                    // Compute next X positions for this frame
                    for (i = 0; i < NUM_PIPES; i = i + 1) begin
                        next_x[i] = pipe_x[i] - pipe_speed;
                    end

                    // Find rightmost among next_x[]
                    rightmost_next = next_x[0];
                    for (i = 1; i < NUM_PIPES; i = i + 1) begin
                        if (next_x[i] > rightmost_next)
                            rightmost_next = next_x[i];
                    end

                    // Wrap base (we increment this per wrapped pipe so they don't stack)
                    base_next = rightmost_next;

                    // Commit updated positions + wrap individually
                    for (i = 0; i < NUM_PIPES; i = i + 1) begin
                        // Wrap when fully off-screen left (right edge <= 0)
                        if ((next_x[i] + PIPE_WIDTH) <= 0) begin
                            base_next = base_next + PIPE_SPACING;
                            pipe_x[i] <= base_next;

                            // New random gap for this pipe
                            lfsr_tmp  = lfsr_next(lfsr_tmp);
                            gap_y[i]  <= gap_from_lfsr(lfsr_tmp);
                        end else begin
                            pipe_x[i] <= next_x[i];
                        end
                    end

                    // Update LFSR state for next frame
                    lfsr <= lfsr_tmp;

                    // ----------------------------
                    // Bird autopilot update (once per frame)
                    // Aim for the CENTER of the next upcoming pipe gap
                    // (UNCHANGED logic — still uses pipe_x[] and gap_y[])
                    // ----------------------------
                    if(!player_mode) begin // Autopilot
                        // 1) Find nearest upcoming pipe
                        next_pipe_idx = -1;
                        best_pipe_x   = 32'sh7FFFFFFF;

                        for (i = 0; i < NUM_PIPES; i = i + 1) begin
                            if ((pipe_x[i] + PIPE_WIDTH) >= BIRD_X) begin
                                if (pipe_x[i] < best_pipe_x) begin
                                    best_pipe_x   = pipe_x[i];
                                    next_pipe_idx = i;
                                end
                            end
                        end

                        // Fallback: pick rightmost pipe
                        if (next_pipe_idx < 0) begin
                            best_pipe_x   = pipe_x[0];
                            next_pipe_idx = 0;

                            for (i = 1; i < NUM_PIPES; i = i + 1) begin
                                if (pipe_x[i] > best_pipe_x) begin
                                    best_pipe_x   = pipe_x[i];
                                    next_pipe_idx = i;
                                end
                            end
                        end

                        // 2) Compute target bird Y (gap center)
                        bird_target_y =
                            gap_y[next_pipe_idx] +
                            (GAP_HEIGHT / 2) -
                            (SPR_H / 2);

                        // Clamp to screen
                        if (bird_target_y < 0)
                            bird_target_y = 0;
                        if (bird_target_y > (FRAME_H - SPR_H))
                            bird_target_y = FRAME_H - SPR_H;

                        // 3) Move bird smoothly
                        if (bird_y < bird_target_y) begin
                            if ((bird_y + BIRD_SPEED) > bird_target_y)
                                bird_y <= bird_target_y;
                            else
                                bird_y <= bird_y + BIRD_SPEED;
                        end
                        else if (bird_y > bird_target_y) begin
                            if ((bird_y - BIRD_SPEED) < bird_target_y)
                                bird_y <= bird_target_y;
                            else
                                bird_y <= bird_y - BIRD_SPEED;
                        end
					// Autopilot end
					end else begin // Player controlled
						// player controls
						// Move UP if switch2 pressed
						if (switch2_db) begin
							if (bird_y >= BIRD_SPEED)
								bird_y <= bird_y - BIRD_SPEED;
							else
								bird_y <= 0; // clamp to top
						end
						// Move DOWN if switch1 pressed
						else if (switch1_db) begin
							if (bird_y + BIRD_SPEED <= FRAME_H - SPR_H)
								bird_y <= bird_y + BIRD_SPEED;
							else
								bird_y <= FRAME_H - SPR_H; // clamp to bottom
						end
                    end
                end

                // 3) Produce pixel and delay timing by 1 cycle
                vid_rgb_d1 <= spr_opaque ? spr_pixel :
                    pipes_hit  ? pipe_pixel :
                    bg_pixel;
                dvh_sync_d1 <= dvh_sync_i;
            end
        end
    end

// ----------------------------
// Outputs
// ----------------------------
assign dvh_sync_o = dvh_sync_d1;
assign vid_rgb_o  = vid_rgb_d1;

endmodule




module button_debounce #(
    parameter int N = 10000,          // number of samples
    parameter int THRESH = 9500       // how many must be '1'
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,
    output reg button_out
);


    // 10 ms @ 1.25 MHz = 12,500 cycles
    localparam integer DEBOUNCE_CNT = 12500;

    reg        button_sync0, button_sync1;
    reg [13:0] counter;
    reg        button_state;
    // 2-FF synchronizer
    always @(posedge clk) begin
        button_sync0 <= button_in;
        button_sync1 <= button_sync0;
    end

    always @(posedge clk) begin
        if (rst) begin
            counter      <= 0;
            button_state <= 0;
            button_out   <= 0;
        end else begin
		if (button_sync1 == button_state) begin
                counter <= 0; // input matches current state
            end else begin
                if (counter == DEBOUNCE_CNT) begin
                    button_state <= button_sync1; // accept new state
                    button_out   <= button_sync1;
                    counter      <= 0;
                end else begin
                    counter <= counter + 1;
                end
            end
        end
    end

endmodule