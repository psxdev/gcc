------------------------------------------------------------------------------
--                                                                          --
--                        GNAT RUN-TIME COMPONENTS                          --
--                                                                          --
--                      S Y S T E M . I M G _ R E A L                       --
--                                                                          --
--                                 B o d y                                  --
--                                                                          --
--          Copyright (C) 1992-2021, Free Software Foundation, Inc.         --
--                                                                          --
-- GNAT is free software;  you can  redistribute it  and/or modify it under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion.  GNAT is distributed in the hope that it will be useful, but WITH- --
-- OUT ANY WARRANTY;  without even the  implied warranty of MERCHANTABILITY --
-- or FITNESS FOR A PARTICULAR PURPOSE.                                     --
--                                                                          --
-- As a special exception under Section 7 of GPL version 3, you are granted --
-- additional permissions described in the GCC Runtime Library Exception,   --
-- version 3.1, as published by the Free Software Foundation.               --
--                                                                          --
-- You should have received a copy of the GNU General Public License and    --
-- a copy of the GCC Runtime Library Exception along with this program;     --
-- see the files COPYING3 and COPYING.RUNTIME respectively.  If not, see    --
-- <http://www.gnu.org/licenses/>.                                          --
--                                                                          --
-- GNAT was originally developed  by the GNAT team at  New York University. --
-- Extensive contributions were provided by Ada Core Technologies Inc.      --
--                                                                          --
------------------------------------------------------------------------------

with System.Img_LLU;    use System.Img_LLU;
with System.Img_Uns;    use System.Img_Uns;
with System.Img_Util;   use System.Img_Util;
with System.Powten_LLF; use System.Powten_LLF;

with System.Float_Control;

package body System.Img_Real is

   subtype LLU is Long_Long_Unsigned;

   --  The following defines the maximum number of digits that we can convert
   --  accurately. This is limited by the precision of Long_Long_Float, and
   --  also by the number of digits we can hold in Long_Long_Unsigned, which
   --  is the integer type we use as an intermediate for the result.

   --  We assume that in practice, the limitation will come from the digits
   --  value, rather than the integer value. This is true for typical IEEE
   --  implementations, and at worst, the only loss is for some precision
   --  in very high precision floating-point output.

   --  Note that in the following, the "-2" accounts for the space and one
   --  extra digit, since we need the maximum number of 9's that can be
   --  represented, e.g. for the 64-bit case, Long_Long_Unsigned'Width is
   --  21, since the maximum value (approx 1.8E+19) has 20 digits, but the
   --  maximum number of 9's that can be represented is only 19.

   Maxdigs : constant := Natural'Min (LLU'Width - 2, Long_Long_Float'Digits);

   Maxscaling : constant := 5000;
   --  Max decimal scaling required during conversion of floating-point
   --  numbers to decimal. This is used to defend against infinite
   --  looping in the conversion, as can be caused by erroneous executions.
   --  The largest exponent used on any current system is 2**16383, which
   --  is approximately 10**4932, and the highest number of decimal digits
   --  is about 35 for 128-bit floating-point formats, so 5000 leaves
   --  enough room for scaling such values

   function Is_Negative (V : Long_Long_Float) return Boolean;
   --  Return True if V is negative for the purpose of the output, i.e. return
   --  True for negative zeros only if Signed_Zeros is True.

   --------------------------
   -- Image_Floating_Point --
   --------------------------

   procedure Image_Floating_Point
     (V    : Long_Long_Float;
      S    : in out String;
      P    : out Natural;
      Digs : Natural)
   is
      pragma Assert (S'First = 1);

   begin
      --  Decide whether a blank should be prepended before the call to
      --  Set_Image_Real. We generate a blank for positive values, and
      --  also for positive zeros. For negative zeros, we generate a
      --  blank only if Signed_Zeros is False (the RM only permits the
      --  output of -0.0 when Signed_Zeros is True). We do not generate
      --  a blank for positive infinity, since we output an explicit +.

      if not Is_Negative (V) and then V <= Long_Long_Float'Last then
         pragma Annotate (CodePeer, False_Positive, "condition predetermined",
                          "CodePeer analysis ignores NaN and Inf values");
         pragma Assert (S'Last > 1);
         --  The caller is responsible for S to be large enough for all
         --  Image_Floating_Point operation.
         S (1) := ' ';
         P := 1;
      else
         P := 0;
      end if;

      Set_Image_Real (V, S, P, 1, Digs - 1, 3);
   end Image_Floating_Point;

   --------------------------------
   -- Image_Ordinary_Fixed_Point --
   --------------------------------

   procedure Image_Ordinary_Fixed_Point
     (V   : Long_Long_Float;
      S   : in out String;
      P   : out Natural;
      Aft : Natural)
   is
      pragma Assert (S'First = 1);

   begin
      --  Output space at start if non-negative

      if V >= 0.0 then
         S (1) := ' ';
         P := 1;
      else
         P := 0;
      end if;

      Set_Image_Real (V, S, P, 1, Aft, 0);
   end Image_Ordinary_Fixed_Point;

   -----------------
   -- Is_Negative --
   -----------------

   function Is_Negative (V : Long_Long_Float) return Boolean is
   begin
      if V < 0.0 then
         return True;

      elsif V > 0.0 then
         return False;

      elsif not Long_Long_Float'Signed_Zeros then
         return False;

      else
         return Long_Long_Float'Copy_Sign (1.0, V) < 0.0;
      end if;
   end Is_Negative;

   --------------------
   -- Set_Image_Real --
   --------------------

   procedure Set_Image_Real
     (V    : Long_Long_Float;
      S    : in out String;
      P    : in out Natural;
      Fore : Natural;
      Aft  : Natural;
      Exp  : Natural)
   is
      NFrac : constant Natural := Natural'Max (Aft, 1);
      --  Number of digits after the decimal point

      Digs : String (1 .. 3 + Maxdigs);
      --  Array used to hold digits of converted integer value

      Ndigs : Natural;
      --  Number of digits stored in Digs (and also subscript of last digit)

      Scale : Integer := 0;
      --  Exponent such that the result is Digs (1 .. NDigs) * 10**(-Scale)

      X : Long_Long_Float;
      --  Current absolute value of the input after scaling

      procedure Adjust_Scale (S : Natural);
      --  Adjusts the value in X by multiplying or dividing by a power of
      --  ten so that it is in the range 10**(S-1) <= X < 10**S. Scale is
      --  adjusted to reflect the power of ten used to divide the result,
      --  i.e. one is added to the scale value for each multiplication by
      --  10.0 and one is subtracted for each division by 10.0.

      ------------------
      -- Adjust_Scale --
      ------------------

      procedure Adjust_Scale (S : Natural) is
         Lo  : Natural;
         Hi  : Natural;
         Mid : Natural;
         XP  : Long_Long_Float;

      begin
         --  Cases where scaling up is required

         if X < Powten (S - 1) then

            --  What we are looking for is a power of ten to multiply X by
            --  so that the result lies within the required range.

            loop
               XP := X * Powten (Maxpow);
               exit when XP >= Powten (S - 1) or else Scale > Maxscaling;
               X := XP;
               Scale := Scale + Maxpow;
            end loop;

            --  The following exception is only raised in case of erroneous
            --  execution, where a number was considered valid but still
            --  fails to scale up. One situation where this can happen is
            --  when a system which is supposed to be IEEE-compliant, but
            --  has been reconfigured to flush denormals to zero.

            if Scale > Maxscaling then
               raise Constraint_Error;
            end if;

            --  Here we know that we must multiply by at least 10**1 and that
            --  10**Maxpow takes us too far: binary search to find right one.

            --  Because of roundoff errors, it is possible for the value
            --  of XP to be just outside of the interval when Lo >= Hi. In
            --  that case we adjust explicitly by a factor of 10. This
            --  can only happen with a value that is very close to an
            --  exact power of 10.

            Lo := 1;
            Hi := Maxpow;

            loop
               Mid := (Lo + Hi) / 2;
               XP := X * Powten (Mid);

               if XP < Powten (S - 1) then

                  if Lo >= Hi then
                     Mid := Mid + 1;
                     XP := XP * 10.0;
                     exit;

                  else
                     Lo := Mid + 1;
                  end if;

               elsif XP >= Powten (S) then

                  if Lo >= Hi then
                     Mid := Mid - 1;
                     XP := XP / 10.0;
                     exit;

                  else
                     Hi := Mid - 1;
                  end if;

               else
                  exit;
               end if;
            end loop;

            X := XP;
            Scale := Scale + Mid;

         --  Cases where scaling down is required

         elsif X >= Powten (S) then

            --  What we are looking for is a power of ten to divide X by
            --  so that the result lies within the required range.

            pragma Assert (Powten (Maxpow) /= 0.0);

            loop
               XP := X / Powten (Maxpow);
               exit when XP < Powten (S) or else Scale < -Maxscaling;
               X := XP;
               Scale := Scale - Maxpow;
            end loop;

            --  The following exception is only raised in case of erroneous
            --  execution, where a number was considered valid but still
            --  fails to scale up. One situation where this can happen is
            --  when a system which is supposed to be IEEE-compliant, but
            --  has been reconfigured to flush denormals to zero.

            if Scale < -Maxscaling then
               raise Constraint_Error;
            end if;

            --  Here we know that we must divide by at least 10**1 and that
            --  10**Maxpow takes us too far, binary search to find right one.

            Lo := 1;
            Hi := Maxpow;

            loop
               Mid := (Lo + Hi) / 2;
               XP := X / Powten (Mid);

               if XP < Powten (S - 1) then

                  if Lo >= Hi then
                     XP := XP * 10.0;
                     Mid := Mid - 1;
                     exit;

                  else
                     Hi := Mid - 1;
                  end if;

               elsif XP >= Powten (S) then

                  if Lo >= Hi then
                     XP := XP / 10.0;
                     Mid := Mid + 1;
                     exit;

                  else
                     Lo := Mid + 1;
                  end if;

               else
                  exit;
               end if;
            end loop;

            X := XP;
            Scale := Scale - Mid;

         --  Here we are already scaled right

         else
            null;
         end if;
      end Adjust_Scale;

   --  Start of processing for Set_Image_Real

   begin
      --  We call the floating-point processor reset routine so we can be sure
      --  that the processor is properly set for conversions. This is notably
      --  needed on Windows, where calls to the operating system randomly reset
      --  the processor into 64-bit mode.

      System.Float_Control.Reset;

      --  Deal with invalid values first

      if not V'Valid then

         --  Note that we're taking our chances here, as V might be
         --  an invalid bit pattern resulting from erroneous execution
         --  (caused by using uninitialized variables for example).

         --  No matter what, we'll at least get reasonable behavior,
         --  converting to infinity or some other value, or causing an
         --  exception to be raised is fine.

         --  If the following two tests succeed, then we definitely have
         --  an infinite value, so we print +Inf or -Inf.

         if V > Long_Long_Float'Last then
            pragma Annotate (CodePeer, False_Positive, "dead code",
                             "CodePeer analysis ignores NaN and Inf values");
            pragma Annotate (CodePeer, False_Positive, "test always true",
                             "CodePeer analysis ignores NaN and Inf values");

            Set_Floating_Invalid_Value (Infinity, S, P, Fore, Aft, Exp);

         elsif V < Long_Long_Float'First then
            Set_Floating_Invalid_Value (Minus_Infinity, S, P, Fore, Aft, Exp);

         --  In all other cases we print NaN

         else
            Set_Floating_Invalid_Value (Not_A_Number, S, P, Fore, Aft, Exp);
         end if;

         return;
      end if;

      --  Set the first character like Image

      Digs (1) := (if Is_Negative (V) then '-' else ' ');
      Ndigs := 1;

      X := abs (V);

      --  If X is zero, we are done

      if X = 0.0 then
         Digs (2) := '0';
         Ndigs := 2;

      --  Otherwise, scale X and convert it to an integer

      else
         --  In exponent notation, we need exactly NFrac + 1 digits and always
         --  round the last one.

         if Exp > 0 then
            Adjust_Scale (Natural'Min (NFrac + 1, Maxdigs));
            X := X + 0.5;

         --  In straight notation, we compute the maximum number of digits and
         --  compare how many of them will be put after the decimal point with
         --  Nfrac, in order to find out whether we need to round the last one
         --  here or whether the rounding is performed by Set_Decimal_Digits.

         else
            Adjust_Scale (Maxdigs);
            if Scale <= NFrac then
               X := X + 0.5;
            end if;
         end if;

         --  Use Unsigned routine if possible, since on 32-bit machines it will
         --  be significantly more efficient than the Long_Long_Unsigned one.

         if X <= Long_Long_Float (Unsigned'Last) then
            declare
               I : constant Unsigned :=
                     Unsigned (Long_Long_Float'Truncation (X));
            begin
               Set_Image_Unsigned (I, Digs, Ndigs);
            end;

         else pragma Assert (X <= Long_Long_Float (LLU'Last));
            declare
               I : constant LLU :=
                     LLU (Long_Long_Float'Truncation (X));
            begin
               Set_Image_Long_Long_Unsigned (I, Digs, Ndigs);
            end;
         end if;
      end if;

      Set_Decimal_Digits (Digs, Ndigs, S, P, Scale, Fore, Aft, Exp);
   end Set_Image_Real;

end System.Img_Real;
