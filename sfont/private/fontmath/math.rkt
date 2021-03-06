#lang racket
(require "interpolables.rkt"
         "info-kern-math.rkt"
         "../../main.rkt"
         "../../geometry.rkt"
         "../../properties.rkt"
         "../../utilities.rkt"
         (for-syntax racket/syntax))

(provide (except-out (all-from-out racket) + - * /)
         (contract-out
          [fontmath-object/c (-> any/c boolean?)]
          [font-intp-object/c (-> any/c boolean?)]
          [get-interpolable-fonts (->* () () #:rest (listof font?) (listof font?))]
          [rename prod * (->* (fontmath-object/c) () #:rest (listof fontmath-object/c) fontmath-object/c)]
          [rename add  + (->* (fontmath-object/c) () #:rest (listof fontmath-object/c) fontmath-object/c)]
          [rename sub  - (->* (fontmath-object/c) () #:rest (listof fontmath-object/c) fontmath-object/c)]
          [rename div  / (->* (fontmath-object/c) () #:rest (listof fontmath-object/c) fontmath-object/c)]
          [x-> (-> geometric? geometric?)]
          [y-> (-> geometric? geometric?)]
          [fix-components (-> font? font? font?)])
         define-interpolable-fonts
         define-space
         use-only-glyphs)
   
         
(define fontmath-object/c
  (flat-named-contract 
   'fontmath-object/c
   (or/c vec? real? font? glyph? bezier/c)))

(define font-intp-object/c
  (flat-named-contract 
   'font-object/c
   (or/c vec? font? glyph? layer? contour? anchor? component? fontinfo/c kerning/c)))

(define mathfilter
  (make-parameter #f))

(define-syntax use-only-glyphs 
  (syntax-rules ()
    [(_ gs . body)
     (parameterize [(mathfilter gs)] . body)]))

; Font (listof Symbol) -> Font
(define (only-glyphs-in gl f)
    (struct-copy font f
                 [glyphs (filter-glyphs 
                          (lambda (g)
                            (member (glyph-name g) gl))
                          f)]))
;                 [layers (map-layers
;                          (lambda (l)
;                            (struct-copy layer l
;                                         [glyphs (filter-glyphs 
;                                                  (lambda (g)
;                                                    (member (glyph-name g) gl))
;                                                  l)]))
;                            f)]))

; Symbol Font -> (listof Symbol)
(define (component-deps g f)
    (let ([cs (map component-base (layer-components (get-layer (get-glyph f g) foreground)))])
      (append* cs (map (lambda (g) (component-deps g f)) cs))))

; Font -> Font
(define (reduced-font f)
  (let ([ls (if (mathfilter)
                 (remove-duplicates 
                  (apply append (mathfilter) 
                         (map (lambda (g) (component-deps g f)) (mathfilter))))
                 #f)])
    (if ls (only-glyphs-in ls f) f)))


; Point ... -> Point
(define (point+ p1 . ps)
  (letrec ([p+ (lambda (p1 p2)
                 (struct-copy point p1
                              [pos (vec+ (point-pos p1) (point-pos p2))]))])
    (foldl p+ p1 ps)))

; Contour ... -> Contour
(define (contour+ c1 . cs)
  (struct-copy contour c1
               [points (apply map 
                              (lambda (p1 . ps)
                                (foldl point+ p1 ps))
                              (contour-points c1)
                              (map contour-points cs))]))

; Component ... -> Component
(define (component+ c1 . cs)
  (struct-copy component c1
        [matrix (foldl (lambda (cc1 cc2) 
                         (match cc1
                           [(trans-mat x xy yx y xo yo)
                            (match cc2
                              [(trans-mat x2 xy2 yx2 y2 xo2 yo2)
                               (trans-mat (+ x x2) (+ xy xy2) (+ yx yx2) (+ y y2) (+ xo xo2) (+ yo yo2))])]))
                       (get-matrix c1)
                       (map get-matrix cs))]))

; Anchor ... -> Anchor
(define (anchor+ a1 . as)
  (struct-copy anchor a1
               [pos (foldl vec+ (get-position a1)
                           (map get-position as))]))

; Advance ... -> Advance
(define (advance+ a1 . as)
  (struct-copy advance a1
               [width  (foldl + (advance-width  a1) (map advance-width  as))]
               [height (foldl + (advance-height a1) (map advance-height as))]))

; Layer ... -> Layer
(define (layer+ l1 . ls)
  (let [(lss (cons l1 ls))]
    (struct-copy layer l1
                 [contours
                  (apply map contour+ (map layer-contours lss))]
                 [components
                  (apply map component+ (map layer-components lss))]
                 [anchors
                  (apply map anchor+ (map layer-anchors lss))])))

; Glyph ... -> Glyph
(define (glyph+ g1 . gs)
  (let [(gss (cons g1 gs))]
    (struct-copy glyph g1
                 [advance (apply advance+ (map glyph-advance gss))]
                 [layers 
                  (list (apply layer+ (map (curryr get-layer foreground) gss)))])))

; Font Real Real -> Any
(define (font-scale* o fx [fy fx])
  (let ([o1 (scale o fx fy)])
    (struct-copy font o1
                 [fontinfo (info-scale (font-fontinfo o1) fx fy)]
                 [kerning (kerning-scale (font-kerning o1) fx)])))

; Font ... -> Font
(define (font+ f1 . fs)
  (if (null? fs)
      f1
      (let ([f+ (lambda (f1 f2)
                  (struct-copy font f1
                               [fontinfo (info+ (font-fontinfo f1) (font-fontinfo f2))]
                               [kerning (kerning+ (font-kerning f1) (font-kerning f2))]
                               [glyphs (map glyph+ (font-glyphs-list f1) 
                                                   (font-glyphs-list f2))]))]
            [fonts (map reduced-font (cons f1 fs))])
        (foldl f+ (car fonts) (cdr fonts)))))

; Font Real ... -> Font
(define (font* f s1 . ss)
  (let ([s (apply * (cons s1 ss))])
    (if (= 1 s) f
        (font-scale* (reduced-font f) s))))

; FontObject Real ... -> FontObject
(define (font:* o s1 . ss)
  ((match o
     [(? font? _) font*]
     [(? glyph? _) scale]
     [(? layer? _) scale]
     [(? contour? _) scale]
     [(? anchor? _ ) scale]
     [(? component? _) scale]
     [_ (error "Error: wrong type for font:*")])
   o
   (apply * (cons s1 ss))))

; FontObject ... -> FontObject
(define (font:+ o1 . os)
  (apply (match o1
           [(? font? _) font+]
           [(? glyph? _) glyph+]
           [(? layer? _) layer+]
           [(? contour? _) contour+]
           [(? anchor? _ ) anchor+]
           [(? component? _) component+]
           [_ (error "Error: wrong type for font:+")])
         (cons o1 os)))

; FontObject ... -> FontObject
(define (font:- o1 . os)
  (font:+ o1 (font:* (apply font:+ os) -1)))
          

; FontObject Real ... -> FontObject
(define (font:/ o s1 . ss)
  (font:* o (apply * (map (lambda (s) 
                                (/ 1 s)) 
                              (cons s1 ss)))))

; FontMathObject ... -> FontMathObject
(define (add a . as)
  (match (cons a as)
    [(list (? font? _) ...)
     (apply font:+ a as)]
    [(list (? glyph? _) ...)
     (apply font:+ a as)]
    [(list (? layer? _) ...)
     (apply font:+ a as)]
    [(list (? real? _) ...)
     (apply + a as)]
    [(list (? vec? _) ...)
     (foldl vec+ a as)]
    [(list (? bezier/c _) ...)
     (foldl (lambda (a b) (map vec+ a b)) a as)]
    [_ (error "Invalid operands for product for addition")]))

; FontMathObject -> FontMathObject
(define (sub a . as)
  (match (cons a as)
    [(list (? font? _) ...)
     (apply font:+ a (map (lambda (i) (prod i -1)) as))]
    [(list (? glyph? _) ...)
     (apply font:+ a (map (lambda (i) (prod i -1)) as))]
    [(list (? layer? _) ...)
     (apply font:+ a (map (lambda (i) (prod i -1)) as))]
    [(list (? real? _) ...)
     (apply - a as)]
    [(list (? vec? _) ...)
     (foldl vec- a as)]
    [(list (? bezier/c _) ...)
     (foldl (lambda (a b) (map vec- a b)) a as)]
    [_ (error "Invalid operands for product for addition")]))

; FontMathObject ... -> FontMathObject
(define (prod a . as)
  (match (cons a as)
    [(list-no-order (? font? f) (? real? s) ...)
     (apply font:* f s)]
    [(list-no-order (? glyph? f) (? real? s) ...)
     (apply font:* f s)]
    [(list-no-order (? layer? f) (? real? s) ...)
     (apply font:* f s)]
    [(list-no-order (? vec? v) (? real? s) ...)
     (vec* v (apply * s))]
    [(list-no-order (? bezier/c b) (? real? s) ...)
     (let ([f (apply * s)])
       (map (lambda (v) (vec* v f)) b ))]
    [(list (? real? x) ...)
     (apply * x)]
    [(list (? vec? v) ...)
     (foldl (lambda (v1 v2)
              (let* ([c1 (make-rectangular (vec-x v1) (vec-y v1))]
                     [c2 (make-rectangular (vec-x v2) (vec-y v2))]
                     [c (* c1 c2)])
                (vec (real-part c) (imag-part c))))
            a as)]
    [(list (? bezier/c b) ...)
     (foldl (lambda (b1 b2) (map prod b1 b2)) a as)]
    [_ (error "Invalid operands for product")]))

; FontMathObject Real ... -> FontMathObject
(define (div a . as)
  (match (cons a as)
    [(list (? font? f) (? real? s) ...)
     (apply font:* f (map (lambda (n) (/ 1.0 n)) s))]
    [(list (? glyph? f) (? real? s) ...)
     (apply font:* f (map (lambda (n) (/ 1.0 n)) s))]
    [(list (? layer? f) (? real? s) ...)
     (apply font:* f (map (lambda (n) (/ 1.0 n)) s))]
    [(list (? vec? v) (? real? s) ...)
     (vec* v (apply * (map (lambda (n) (/ 1.0 n)) s)))]
    [(list (? bezier/c b) (? real? s) ...)
     (let ([f (apply * (map (lambda (n) (/ 1.0 n)) s))])
       (map (lambda (v) (vec* v f)) b ))]
    [(list (? real? x) ...)
     (apply / x)]
    [_ (error "Invalid operands for product")]))


;; PROJECTIONS

; Geometric -> Geometric
; project the object on the x axis (set every y coord. to zero)
(define (x-> o)
  ((if (font? o) font-scale* scale) o 1 0))

; Geometric -> Geometric
; project the object on the y axis (set every x coord. to zero)
(define (y-> o)
  ((if (font? o) font-scale* scale) o 0 1))  

; Font ... -> (listof Font)
(define (interpolables  f . fs)
  (let ([f0 (foldl (lambda (f acc)
                     (let-values ([(a b) (interpolable-fonts acc f #f #t)])
                       a))
                   f fs)])
    (cons f0 (map (lambda (f)
                    (let-values ([(a b) (interpolable-fonts f f0 #f #t)])
                      (match-fonts-contours f0 a)))
                  fs))))


; Font ... -> Font ...
(define (get-interpolable-fonts . fs)
  (apply interpolables
         (map (lambda (f)
                (prepare-font f #f #t))
              fs)))



; Font, Font -> Font
; Produce a new font with components scale fields imported from f2
(define (fix-components f1 f2)
  (struct-copy font f1
               [glyphs
                (map 
                 (lambda (g1 g2)
                   (struct-copy glyph g1
                                [layers 
                                 (list 
                                  (struct-copy layer (get-layer g1 foreground)
                                               [components (map import-component-scale
                                                                (layer-components (get-layer g1 foreground))
                                                                (layer-components (get-layer g2 foreground)))]))]))
                 (font-glyphs-list f1)
                 (font-glyphs-list f2))]))
                                                      


;;; MACROS
(define-syntax-rule (define-interpolable-fonts (id f) ...)
  (define-values (id ...)
    (apply values (interpolables f ...))))


(define-syntax (define-space stx)
  (syntax-case stx ()
    [(define-space id (origin [font ...]))
     (for-each (lambda (i)
                 (unless (identifier? i)
                   (raise-syntax-error #f "Not an identifier" stx i)))
               (append (list #'id #'origin) (syntax->list #'(font ...))))
     (with-syntax ([(fname ...)
                    (map (lambda (f)
                           (format-id stx "~a-~a" #'id f))
                         (syntax->list #'(font ...)))])
       #'(begin
           (define (id f . fs)
             (apply values (map (lambda (f) (add origin f)) (cons f fs))))
           (define fname (sub font origin)) ...))]))




 