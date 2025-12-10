" Leader key (space)
let mapleader = " "

set number
syntax on

set autoindent
set smartindent
set expandtab
set tabstop=2
set shiftwidth=2
set softtabstop=2
filetype indent on

set showmatch
set wildmenu

" Status line
set laststatus=2
set statusline=
set statusline+=%#PmenuSel#
set statusline+=\ %{toupper(mode())}\     " Current mode
set statusline+=%#LineNr#
set statusline+=\ %f                       " Filename
set statusline+=%m                         " Modified flag
set statusline+=%=                         " Right align
set statusline+=%y                         " Filetype
set statusline+=\ %l:%c                    " Line:column
set statusline+=\ %p%%\                    " Percentage
set hlsearch              " Highlight all search results
set incsearch             " Show search matches as you type
set ignorecase            " Ignore case in search patterns
set smartcase             " Override ignorecase if search pattern contains uppercase

set cursorline
" set relativenumber        " Show relative line numbers

set mouse=a

" use 'brew install vim' if shared clipboard doesn't work
set clipboard=unnamed
set backspace=indent,eol,start

" Highlight trailing whitespace
highlight ExtraWhitespace ctermbg=red guibg=red
match ExtraWhitespace /\s\+$/

" Automatically remove trailing whitespace on save
autocmd BufWritePre * :%s/\s\+$//e

" ============================================
" Navigation
" ============================================

" Faster vertical navigation (5 lines at a time)
nnoremap <C-j> 5j
nnoremap <C-k> 5k

" Easier split navigation
nnoremap <C-h> <C-w>h
nnoremap <C-l> <C-w>l

" Buffer navigation
nnoremap <leader>bn :bnext<CR>
nnoremap <leader>bp :bprevious<CR>
nnoremap <leader>bd :bdelete<CR>

" ============================================
" Search
" ============================================

" Clear search highlighting with Escape
nnoremap <Esc> :nohlsearch<CR>

" Keep cursor centered when jumping through search results
nnoremap n nzz
nnoremap N Nzz
nnoremap <C-d> <C-d>zz
nnoremap <C-u> <C-u>zz

" ============================================
" Quality of Life
" ============================================

set showmode              " Show current mode in command line
set ttimeoutlen=10        " Faster escape from insert mode
set scrolloff=8           " Keep 8 lines visible above/below cursor
set matchtime=3           " Show matching brackets longer
